#!/bin/bash

# ChittyOS ChatGPT MCP Deployment Script
# Usage: ./deploy.sh [staging|production]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default environment
ENVIRONMENT=${1:-staging}

echo -e "${BLUE}🚀 ChittyOS ChatGPT MCP Deployment${NC}"
echo -e "${BLUE}Environment: ${ENVIRONMENT}${NC}"
echo ""

# Validate environment
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
    echo -e "${RED}❌ Invalid environment. Use 'staging' or 'production'${NC}"
    exit 1
fi

# Check prerequisites
echo -e "${YELLOW}📋 Checking prerequisites...${NC}"

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    echo -e "${RED}❌ Wrangler CLI not found. Installing...${NC}"
    npm install -g wrangler
fi

# Check if logged into Cloudflare
if ! wrangler whoami &> /dev/null; then
    echo -e "${YELLOW}⚠️  Not logged into Cloudflare. Please login:${NC}"
    wrangler login
fi

# Verify project structure
if [[ ! -f "wrangler.toml" ]]; then
    echo -e "${RED}❌ wrangler.toml not found. Run this script from the project root.${NC}"
    exit 1
fi

if [[ ! -f "src/index.ts" ]]; then
    echo -e "${RED}❌ src/index.ts not found. Ensure project is properly structured.${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"
echo ""

# Environment-specific configuration
echo -e "${YELLOW}🔧 Setting up environment configuration...${NC}"

if [[ "$ENVIRONMENT" == "production" ]]; then
    WORKER_NAME="chitty-chatgpt-mcp-prod"
    DB_NAME="chitty-chatgpt-sessions-prod"
else
    WORKER_NAME="chitty-chatgpt-mcp-staging"
    DB_NAME="chitty-chatgpt-sessions-staging"
fi

echo -e "${BLUE}Worker Name: ${WORKER_NAME}${NC}"
echo -e "${BLUE}Database: ${DB_NAME}${NC}"
echo ""

# Check and set environment variables
echo -e "${YELLOW}🔐 Checking environment variables...${NC}"

check_secret() {
    local secret_name=$1
    if ! wrangler secret list --env "$ENVIRONMENT" | grep -q "$secret_name"; then
        echo -e "${YELLOW}⚠️  Secret '$secret_name' not found. Please set it:${NC}"
        read -p "Enter value for $secret_name: " -s secret_value
        echo ""
        echo "$secret_value" | wrangler secret put "$secret_name" --env "$ENVIRONMENT"
        echo -e "${GREEN}✅ Secret '$secret_name' set${NC}"
    else
        echo -e "${GREEN}✅ Secret '$secret_name' exists${NC}"
    fi
}

check_secret "OPENAI_API_KEY"
check_secret "CHITTY_DATABASE_URL"
check_secret "CHITTY_ENCRYPTION_KEY"

echo ""

# Database setup
echo -e "${YELLOW}🗄️  Setting up database...${NC}"

if [[ -f "schema.sql" ]]; then
    echo -e "${BLUE}Applying database schema...${NC}"
    
    # Get database URL from secrets (for verification)
    echo "Verify your database is accessible and schema is applied."
    echo "Run manually if needed: psql \$CHITTY_DATABASE_URL -f schema.sql"
    
    read -p "Has the database schema been applied? (y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}✅ Database schema confirmed${NC}"
    else
        echo -e "${RED}❌ Please apply database schema before deploying${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠️  schema.sql not found. Database setup may be incomplete.${NC}"
fi

echo ""

# Install dependencies
echo -e "${YELLOW}📦 Installing dependencies...${NC}"
npm install
echo -e "${GREEN}✅ Dependencies installed${NC}"
echo ""

# Type checking
echo -e "${YELLOW}🔍 Running type check...${NC}"
npm run type-check
echo -e "${GREEN}✅ Type check passed${NC}"
echo ""

# Linting (optional)
if command -v eslint &> /dev/null; then
    echo -e "${YELLOW}🧹 Running linter...${NC}"
    npm run lint || echo -e "${YELLOW}⚠️  Linter warnings found (continuing)${NC}"
fi

# Build and deploy
echo -e "${YELLOW}🚀 Deploying to Cloudflare Workers...${NC}"

if [[ "$ENVIRONMENT" == "production" ]]; then
    cf deploy --env production
else
    cf deploy --env staging
fi

echo -e "${GREEN}✅ Deployment successful!${NC}"
echo ""

# Get the deployed URL
WORKER_URL=$(wrangler subdomain 2>/dev/null || echo "your-subdomain")
if [[ "$WORKER_URL" == "your-subdomain" ]]; then
    echo -e "${YELLOW}⚠️  Could not determine worker URL. Check your Cloudflare dashboard.${NC}"
    DEPLOYED_URL="https://${WORKER_NAME}.${WORKER_URL}.workers.dev"
else
    DEPLOYED_URL="https://${WORKER_NAME}.${WORKER_URL}.workers.dev"
fi

echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo ""
echo -e "${BLUE}📋 Deployment Details:${NC}"
echo -e "   Environment: ${ENVIRONMENT}"
echo -e "   Worker URL: ${DEPLOYED_URL}"
echo -e "   Health Check: ${DEPLOYED_URL}/health"
echo ""

# Test deployment
echo -e "${YELLOW}🔍 Testing deployment...${NC}"
if curl -s "${DEPLOYED_URL}/health" | grep -q "healthy"; then
    echo -e "${GREEN}✅ Health check passed${NC}"
else
    echo -e "${YELLOW}⚠️  Health check failed. Check worker logs with: wrangler tail --env ${ENVIRONMENT}${NC}"
fi

echo ""

# MCP Integration instructions
echo -e "${BLUE}🔌 MCP Integration:${NC}"
echo ""
echo "Add this to your MCP client configuration:"
echo ""
echo -e "${GREEN}"
cat << EOF
{
  "mcpServers": {
    "chatgpt": {
      "command": "npx",
      "args": [
        "-y", 
        "@modelcontextprotocol/server-fetch", 
        "${DEPLOYED_URL}"
      ]
    }
  }
}
EOF
echo -e "${NC}"
echo ""

# ChittyOS Integration
echo -e "${BLUE}🏢 ChittyOS Integration:${NC}"
echo ""
echo "Update your ChittyOS configuration:"
echo ""
echo -e "${GREEN}"
cat << EOF
# Add to chittyos/.env
CHITTY_CHATGPT_MCP_URL=${DEPLOYED_URL}
CHITTY_CHATGPT_ENABLED=true

# Add to chittyos/config/mcp-servers.json
{
  "chatgpt-mcp": {
    "url": "${DEPLOYED_URL}",
    "health_endpoint": "/health",
    "capabilities": ["chat", "stream", "analytics", "sessions"]
  }
}
EOF
echo -e "${NC}"
echo ""

# Monitoring
echo -e "${BLUE}📊 Monitoring:${NC}"
echo ""
echo "Available commands:"
echo "  - View logs: wrangler tail --env ${ENVIRONMENT}"
echo "  - Worker stats: wrangler analytics --env ${ENVIRONMENT}"
echo "  - Update secrets: wrangler secret put SECRET_NAME --env ${ENVIRONMENT}"
echo "  - Redeploy: ./deploy.sh ${ENVIRONMENT}"
echo ""

# Security reminders
echo -e "${YELLOW}🔒 Security Reminders:${NC}"
echo "  - Rotate API keys regularly"
echo "  - Monitor usage analytics for anomalies"
echo "  - Review worker logs periodically"
echo "  - Keep dependencies updated"
echo ""

echo -e "${GREEN}🎯 Deployment completed successfully!${NC}"
echo -e "${BLUE}Your ChatGPT MCP server is now live and ready for ChittyOS integration.${NC}"