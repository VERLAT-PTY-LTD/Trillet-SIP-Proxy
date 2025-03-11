# Trillet-SIP-Proxy

A SIP proxy server that forwards SIP traffic to LiveKit's SIP server.

## Features

- Proxies SIP traffic over UDP and TCP
- Forwards all traffic to a configurable target SIP server
- Optional Redis integration
- Docker and Docker Compose support for easy deployment
- AWS deployment with Terraform for a static IP

## Local Development

### Prerequisites

- Go 1.20 or higher
- Docker
- Docker Compose

### Environment Configuration

The project uses environment variables for configuration. You can set these in two ways:

1. Using a `.env` file (recommended)
2. Setting environment variables directly

A template `.env.template` file is provided. Copy it to create your own configuration:

```bash
# Copy the template to create your own .env file
cp .env.template .env

# Edit the .env file with your settings
# nano .env
```

### Running Locally without Docker

You can run the SIP proxy directly without Docker using the provided scripts:

**On Linux/macOS:**
```bash
# Make the script executable
chmod +x run.sh

# Run the SIP proxy
./run.sh
```

**On Windows:**
```powershell
# Run the SIP proxy using PowerShell
.\run.ps1
```

These scripts automatically load environment variables from the `.env` file.

### Running Locally with Docker

Build and run the SIP proxy:

```bash
# Navigate to the sip-proxy directory
cd sip-proxy

# Build the Docker image
docker build -t sip-proxy:local .

# Run the container
docker run -p 5060:5060/udp -p 5060:5060/tcp --name sip-proxy-local sip-proxy:local
```

### Running with Docker Compose

Docker Compose makes it easy to run the SIP proxy with a single command. It automatically uses the `.env` file for configuration:

```bash
# Start the SIP proxy service
docker-compose up -d

# View logs
docker-compose logs -f

# Stop the service
docker-compose down
```

## Configuration

The SIP proxy can be configured using environment variables or command-line flags:

| Environment Variable | Command-line Flag | Description | Default |
|----------------------|-------------------|-------------|---------|
| `BIND_ADDR` | `-bind` | Address to bind the SIP proxy to | `:5060` |
| `LIVEKIT_SIP_ADDR` | `-target` | LiveKit SIP server address | `12uujhkwedv.sip.livekit.cloud:5060` |
| `REDIS_ADDR` | `-redis` | Redis address (optional) | - |

Command-line flags take precedence over environment variables.

## Testing

### Testing with a SIP Client

You can test the SIP proxy using any SIP client, such as:
- Linphone
- Zoiper
- SIPp for load testing

Configure your SIP client to connect to the proxy server's IP address on port 5060.

## AWS Deployment

The project includes Terraform configuration for deploying to AWS with a static IP address.

### Prerequisites for AWS Deployment

- AWS CLI installed and configured with a profile
- Terraform installed (version 1.0.0 or higher)
- Docker installed

### Deployment Steps

1. Update configuration in `terraform/terraform.tfvars`:

```hcl
# AWS Region
aws_region = "us-east-1"

# Redis endpoint (if you have an existing Redis instance)
existing_redis_endpoint = "your-redis-host:6379"
```

If you're using a Redis instance that's only accessible from within your AWS environment (like an ElastiCache instance), you must deploy the SIP proxy in the same VPC or ensure that VPC peering is set up correctly.

2. Run the deployment script:

**On Windows:**
```powershell
.\deploy.ps1
```

**On Linux/macOS:**
```bash
chmod +x deploy.sh
./deploy.sh
```

These scripts will:
- Initialize Terraform
- Create an ECR repository
- Build and push the Docker image
- Deploy the infrastructure to AWS
- Output the static IP address

3. Once deployed, configure your SIP clients to connect to the provided static IP address on port 5060.

### Infrastructure Components

The AWS deployment creates the following resources:
- VPC with a public subnet
- Internet Gateway
- Security Group for SIP traffic
- ECR Repository for the Docker image
- ECS Cluster running on Fargate
- Elastic IP address for static connectivity
- CloudWatch Log Group for logs

### Estimated Cost

This deployment is designed to be cost-effective for low-volume usage:
- Fargate Task (0.25 vCPU, 0.5GB RAM): ~$5-10/month
- Elastic IP (attached to a running instance): ~$3-4/month
- Other AWS resources: ~$1-2/month

Total estimated cost: ~$10-15/month

### Cleanup

To avoid charges, delete all resources when not in use:

```bash
cd terraform
terraform destroy -auto-approve
```