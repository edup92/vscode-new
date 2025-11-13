# SSH Key

resource "tls_private_key" "keypair" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "google_secret_manager_secret" "ssh_keypair" {
  secret_id = local.sshkey_main_name
  replication {
    automatic = true
  }
}

resource "google_secret_manager_secret_version" "ssh_keypair_version" {
  secret      = google_secret_manager_secret.ssh_keypair.id
  secret_data = jsonencode({
    private_key = tls_private_key.keypair.private_key_pem
    public_key  = tls_private_key.keypair.public_key_openssh
  })
}

resource "google_compute_project_metadata" "metadata_keypair" {
  project = var.gcloud_project_id
  metadata = {
    ssh-keys = "vscode:${tls_private_key.keypair.public_key_openssh}"
  }
}

# Instance

resource "local_file" "file_startup" {
  filename        = "${path.module}/tmp/startup.sh"
  file_permission = "0755"
  content = templatefile("${path.module}/startup.sh.tpl", {
    project_name        = var.project_name
    gcloud_project_id   = var.gcloud_project_id
    gcloud_region       = var.gcloud_region
    domain              = var.domain
    admin_email         = var.admin_email
    allowed_countries   = jsonencode(var.allowed_countries)
    oauth_client_id     = var.oauth_client_id
    oauth_client_secret = var.oauth_client_secret
  })
}

resource "google_compute_instance" "instance_vscode" {
  name         = local.instance_vscode_name
  project      = var.gcloud_project_id
  machine_type = "e2-small"
  zone          = data.google_compute_zones.available.names[1]
  metadata = {
    enable-osconfig = "TRUE"
    startup-script  = local_file.file_startup.content
  }
  boot_disk {
    auto_delete = false
    device_name = local.disk_vscode_name
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/ubuntu-minimal-2404-noble-amd64-v20251002"
      size  = 25
      type  = "pd-balanced"
    }
  }
  network_interface {
    network = "default"
    access_config {
      network_tier = "STANDARD"
    }
    stack_type = "IPV4_ONLY"
  }
  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
  scheduling {
    provisioning_model = "STANDARD"
    on_host_maintenance = "MIGRATE"
  }
  labels = {
    goog-ec-src = "vm_add-gcloud"
  }
  reservation_affinity {
    type = "NO_RESERVATION"
  }
  tags = [local.instance_vscode_name]
}

# Playbook

resource "null_resource" "run_ansible" {
  depends_on = [google_compute_instance.instance_vscode]
  provisioner "local-exec" {
    command = <<EOT
      KEY_FILE="/tmp/ssh_key"
      printf "%s" '${tls_private_key.keypair.private_key_pem}' > "$KEY_FILE"
      chmod 600 "$KEY_FILE"
      ansible-playbook -i ${google_compute_instance.instance_vscode.network_interface[0].access_config[0].nat_ip}, \
      --user ubuntu \
      --private-key "$KEY_FILE" \
      playbook.yml
    EOT
  }
}

# Snapshot

resource "google_compute_resource_policy" "snapshot_policy" {
  name   = local.snapshot_vscode_name
  project = var.gcloud_project_id
  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "00:00"
      }
    }
    retention_policy {
      max_retention_days    = 31
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "disk_policy_attachment" {
  name    = google_compute_resource_policy.snapshot_policy.name
  disk    = google_compute_instance.instance_vscode.name
  zone    = data.google_compute_zones.available.names[1]
  project = var.gcloud_project_id

  depends_on = [google_compute_instance.instance_vscode]
}

# Firewall

resource "google_compute_firewall" "allow_lb_hc" {
  name    = local.firewall_vscode_name
  project = var.gcloud_project_id
  network = "default"
  direction = "INGRESS"
  priority  = 1000
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = [local.instance_vscode_name]
}

# Cloud armor

resource "google_compute_security_policy" "cloudarmor_main" {
  name        = local.cloudarmor_vscode_name
  rule {
    priority    = 1000
    description = "Allow specified countries"
    match {
      expr {
        expression = join(" || ", [for country in var.allowed_countries : "origin.region_code == '${country}'"])
      }
    }
    action = "allow"
  }
  rule {
    priority    = 2147483647
    description = "Default deny rule"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    action = "deny(403)"
  }
}

# Instancegroup

resource "google_compute_instance_group" "instancegroup_vscode" {
  name        = local.instancegroup_vscode_name
  zone     = data.google_compute_zones.available.names[1]
  instances   = [google_compute_instance.instance_vscode.self_link]
  named_port {
    name = "https"
    port = 443
  }
}

# Healthcheck

resource "google_compute_health_check" "healthcheck_https" {
  name               = local.healthcheck_443_name
  check_interval_sec = 30
  timeout_sec        = 10
  healthy_threshold  = 2
  unhealthy_threshold = 3
  tcp_health_check {
    port = 443
  }
}

# Backend Service

resource "google_compute_backend_service" "backend_main" {
  name                  = local.backend_vscode_name
  protocol              = "HTTPS"
  port_name             = "https"
  health_checks         = [google_compute_health_check.healthcheck_https.id]
  connection_draining_timeout_sec = 10
  load_balancing_scheme = "EXTERNAL"
  security_policy = google_compute_security_policy.cloudarmor_main.id
  backend {
    group           = google_compute_instance_group.instancegroup_vscode.self_link
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

}

# Urlmap

resource "google_compute_url_map" "urlmap_main" {
  name            = local.urlmap_vscode_name
  default_service = google_compute_backend_service.backend_main.id
}

# SSL

resource "google_compute_managed_ssl_certificate" "ssl_main" {
  name = local.ssl_vscode_name
  managed {
    domains = [var.domain]
  }
}

# ALB

resource "google_compute_global_address" "lb_ip" {
  name = local.lbip_vscode_name
}

resource "google_compute_target_https_proxy" "lbtarget_main" {
  name             = local.lbtarget_vscode_name
  url_map          = google_compute_url_map.urlmap_main.id
  ssl_certificates = [google_compute_managed_ssl_certificate.ssl_main.id]
}

resource "google_compute_global_forwarding_rule" "lb_rule" {
  name                  = local.lbrule_vscode_name
  target                = google_compute_target_https_proxy.lbtarget_main.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL"
  ip_address            = google_compute_global_address.lb_ip.address
}

# Record

output "vscode_lb_ip" {
  description = "Public IP address of the HTTPS Load Balancer"
  value       = google_compute_global_address.lb_ip.address
}