# Google Cloud VSCode

# Whats inside

- Creates gcloud infra (instance, load balancer, firewall, waf, managed ssl, dns record)
- Installs vscode containers with Google SSO proxy

# Usage instructions

### 1) In google cloud create project. Enable compute, dns, secrets and bucket api

### 2) Login in Google Cloud Shell

### 3) Clone repository

```bash
git clone https://github.com/edup92/gcloud-vscode-googlesso.git
```

### 4) Create vars.json file
```bash
cat > gcloud-vscode-googlesso/vars.json <<EOF
{ 
  "project_name": "demo",
  "gcloud_project_id":"demo",
  "gcloud_region":"demo",
  "domain": "demo.tld",
  "admin_email": "demo",
  "allowed_countries": [],
  "oauth_client_id": "demo",
  "oauth_client_secret": "demo"
}
EOF
```

### 4) Run runme.sh

```bash
chmod +x gcloud-vscode-googlesso/runnme.sh ; gcloud-vscode-googlesso/runnme.sh
```

### 5) Point the ip to the record in your DNS zone

### 6) Save SSHKeypair and Ouath Key and secret from Gcloud secrets

### View status
```bash
sudo -u code bash -c 'cd /opt/code-server/docker && docker compose ps'
```