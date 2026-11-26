# Ascender job image for EIS hosts: stock EE + what our aws_ssm / Vault setup needs.
# Local demo build (arm64). For real use: build in CI per arch and push to ECR.
FROM ghcr.io/ctrliq/ascender-ee:25.6.3
USER root
RUN dnf install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_arm64/session-manager-plugin.rpm \
 && dnf clean all \
 && python3 -m pip install --no-cache-dir hvac \
 && ansible-galaxy collection install community.hashi_vault community.docker -p /usr/share/ansible/collections
USER 1000
