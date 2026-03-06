#!/usr/bin/env bash
# ============================================================
#  Push this project to GitHub
#  Run once from your local machine (not from Proxmox)
# ============================================================
set -euo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BOLD}Push OpenVPN Panel to GitHub${NC}"
echo ""

# Check git is installed
command -v git &>/dev/null || { echo "Install git first: https://git-scm.com"; exit 1; }

# Get GitHub username
read -p "Your GitHub username: " GH_USER
read -p "Repo name [openvpn-panel]: " REPO_NAME
REPO_NAME="${REPO_NAME:-openvpn-panel}"

REPO_URL="https://github.com/${GH_USER}/${REPO_NAME}.git"

echo ""
echo -e "${BLUE}Steps:${NC}"
echo -e "  1. Go to https://github.com/new"
echo -e "  2. Create a repo named: ${BOLD}${REPO_NAME}${NC}"
echo -e "  3. Keep it empty (no README)"
echo ""
read -p "Press Enter when repo is created..."

# Init and push
cd "$(dirname "$0")/.."
git init
git add .
git commit -m "Initial commit: OpenVPN Web Panel"
git branch -M main
git remote remove origin 2>/dev/null || true
git remote add origin "$REPO_URL"
git push -u origin main

echo ""
echo -e "${GREEN}${BOLD}✓ Pushed to GitHub!${NC}"
echo ""
echo -e "Your one-line install command:"
echo -e "${BOLD}  curl -fsSL https://raw.githubusercontent.com/${GH_USER}/${REPO_NAME}/main/scripts/install.sh | bash${NC}"
echo ""
echo -e "Update install.sh with your username:"
echo -e "  sed -i 's|YOUR_USERNAME|${GH_USER}|g' scripts/install.sh"
echo -e "  git add . && git commit -m 'Set GitHub username' && git push"
echo ""
