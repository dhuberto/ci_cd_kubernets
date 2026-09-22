#!/bin/bash
# =============================================================================
# user_data.sh — bootstrap da EC2
# =============================================================================
# O K3s é instalado pelo Ansible (playbook.yml), não aqui.
# Este script só garante o básico (git, curl) e deixa um marcador.
# =============================================================================
set -euxo pipefail

# Instala apenas o básico. O Docker NÃO é mais necessário, porque o K3s
# traz o containerd embutido como runtime de container.
dnf install -y git curl

# Marcador para debug: confirma que o user_data terminou com sucesso.
echo "user_data OK em $(date)" > /home/ec2-user/user_data.done
chown ec2-user:ec2-user /home/ec2-user/user_data.done
