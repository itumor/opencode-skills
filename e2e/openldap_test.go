package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/ssh"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func TestOpenLDAP(t *testing.T) {
	t.Parallel()

	if os.Getenv("AWS_ACCESS_KEY_ID") == "" && os.Getenv("AWS_PROFILE") == "" && os.Getenv("AWS_SDK_LOAD_CONFIG") == "" {
		t.Skip("AWS credentials not detected (set AWS_PROFILE or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)")
	}

	repoRoot, err := os.Getwd()
	require.NoError(t, err)
	// e2e/ -> repo root
	repoRoot = filepath.Clean(filepath.Join(repoRoot, ".."))
	tfDir := filepath.Join(repoRoot, "terraform", "openldap")

	tfOpts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: tfDir,
		NoColor:      true,
		EnvVars: map[string]string{
			// This repo uses an S3 backend configured via terraform/openldap/backend.hcl.
			"TF_CLI_ARGS_init": "-backend-config=backend.hcl",
		},
	})

	if os.Getenv("SKIP_DESTROY") != "1" {
		defer terraform.Destroy(t, tfOpts)
	}

	terraform.InitAndApply(t, tfOpts)

	publicIPs := terraform.OutputMap(t, tfOpts, "instance_public_ips")
	require.NotEmpty(t, publicIPs)

	liveMasterIP, ok := publicIPs["live-master-1"]
	require.True(t, ok, "missing output instance_public_ips[\"live-master-1\"]")
	require.NotEmpty(t, liveMasterIP)

	liveReplicaIP, ok := publicIPs["live-replica-1"]
	require.True(t, ok, "missing output instance_public_ips[\"live-replica-1\"]")
	require.NotEmpty(t, liveReplicaIP)

	keyPath := os.Getenv("OPENLDAP_SSH_KEY_PATH")
	if keyPath == "" {
		keyPath = filepath.Join(tfDir, ".local-ssh", "openldap_mm")
	}
	keyBytes, err := os.ReadFile(keyPath)
	require.NoError(t, err, "failed to read SSH key (set OPENLDAP_SSH_KEY_PATH if needed)")

	user := os.Getenv("OPENLDAP_SSH_USER")
	if user == "" {
		user = "ec2-user"
	}

	adminDN := "cn=admin,dc=cae,dc=local"
	adminPW := "admin"
	baseDN := "dc=cae,dc=local"

	masterHost := ssh.Host{
		Hostname:    liveMasterIP,
		SshUserName: user,
		SshKeyPair:  &ssh.KeyPair{PrivateKey: string(keyBytes)},
	}
	replicaHost := ssh.Host{
		Hostname:    liveReplicaIP,
		SshUserName: user,
		SshKeyPair:  &ssh.KeyPair{PrivateKey: string(keyBytes)},
	}

	// Sanity: service + bind + base DN exists.
	_, err = ssh.CheckSshCommandE(t, masterHost, `sudo systemctl is-active --quiet symas-openldap-servers || sudo systemctl is-active --quiet slapd`)
	require.NoError(t, err)

	out, err := ssh.CheckSshCommandE(t, masterHost, fmt.Sprintf(`sudo /opt/symas/bin/ldapwhoami -x -ZZ -H ldap://localhost:389 -D %q -w %q`, adminDN, adminPW))
	require.NoError(t, err)
	require.True(t, strings.Contains(out, "dn:"+adminDN) || strings.Contains(out, "dn: "+adminDN), out)

	out, err = ssh.CheckSshCommandE(t, masterHost, fmt.Sprintf(`sudo /opt/symas/bin/ldapsearch -LLL -x -ZZ -H ldap://localhost:389 -D %q -w %q -b %q -s base dn`, adminDN, adminPW, baseDN))
	require.NoError(t, err)
	require.Contains(t, out, "dn: "+baseDN)

	// Replication: write on master, read on replica.
	uid := "e2e-" + random.UniqueId()
	dn := fmt.Sprintf("uid=%s,ou=people,%s", uid, baseDN)
	ldif := fmt.Sprintf(`dn: %s
objectClass: inetOrgPerson
uid: %s
sn: %s
cn: %s
`, dn, uid, uid, uid)

	// Add on master.
	addCmd := fmt.Sprintf(`cat >/tmp/%s.ldif <<'LDIF'
%s
LDIF
sudo /opt/symas/bin/ldapadd -x -ZZ -H ldap://localhost:389 -D %q -w %q -f /tmp/%s.ldif`, uid, ldif, adminDN, adminPW, uid)
	_, err = ssh.CheckSshCommandE(t, masterHost, addCmd)
	require.NoError(t, err)

	// Wait until it appears on replica.
	_, err = retry.DoWithRetryE(t, "wait for replication", 45, 2*time.Second, func() (string, error) {
		out, err := ssh.CheckSshCommandE(t, replicaHost, fmt.Sprintf(`sudo /opt/symas/bin/ldapsearch -LLL -x -ZZ -o nettimeout=5 -o timelimit=10 -H ldap://localhost:389 -D %q -w %q -b %q "(uid=%s)" dn`, adminDN, adminPW, baseDN, uid))
		if err != nil {
			return "", err
		}
		if !strings.Contains(out, "dn: "+dn) {
			return out, fmt.Errorf("not found yet")
		}
		return out, nil
	})
	require.NoError(t, err)

	// Replica should be read-only (ldapadd should fail).
	_, err = ssh.CheckSshCommandE(t, replicaHost, fmt.Sprintf(`set +e; sudo /opt/symas/bin/ldapadd -x -ZZ -H ldap://localhost:389 -D %q -w %q -f /tmp/%s.ldif >/tmp/ldapadd.out 2>/tmp/ldapadd.err; rc=$?; test $rc -ne 0`, adminDN, adminPW, uid))
	require.NoError(t, err)

	// Cleanup: delete on master and wait until gone everywhere.
	_, _ = ssh.CheckSshCommandE(t, masterHost, fmt.Sprintf(`sudo /opt/symas/bin/ldapdelete -x -ZZ -H ldap://localhost:389 -D %q -w %q %q || true`, adminDN, adminPW, dn))
	_, err = retry.DoWithRetryE(t, "wait for delete replication", 45, 2*time.Second, func() (string, error) {
		out, err := ssh.CheckSshCommandE(t, replicaHost, fmt.Sprintf(`sudo /opt/symas/bin/ldapsearch -LLL -x -ZZ -o nettimeout=5 -o timelimit=10 -H ldap://localhost:389 -D %q -w %q -b %q "(uid=%s)" dn`, adminDN, adminPW, baseDN, uid))
		if err != nil {
			return "", err
		}
		if strings.Contains(out, "dn: "+dn) {
			return out, fmt.Errorf("still present")
		}
		return out, nil
	})
	require.NoError(t, err)
}
