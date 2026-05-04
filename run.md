How to run:

One command to build everything (infra + OpenLDAP + LDIF + tests):

terraform -chdir=terraform/openldap apply

Destroy:

terraform -chdir=terraform/openldap destroy

One command full E2E (apply + verify via SSH + destroy):

go test ./e2e -v -run TestOpenLDAP -timeout 120m