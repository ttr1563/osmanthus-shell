# AWS Systems Manager Session Manager

Session Manager starts `sh` by default on Linux and does not have to enter
through the account's login shell. Protected-root enforcement remains active
at the kernel boundary, but a default SSM session does not produce the Osmanthus PTY
transcript.

Use `ops/ssm/osmanthus-session.json` as a custom Session document. Its Linux shell
profile replaces the default shell process with `/usr/bin/osmanthus-shell`. The
template intentionally keeps S3 and CloudWatch streaming disabled; Osmanthus writes
its local JSONL evidence independently.

## Prerequisites

1. Install and start the packaged `osmanthusd` service.
2. Determine the UID and real shell of the identity used by Session Manager.
3. Enroll that non-root UID with its current real shell:

   ```bash
   id ssm-user
   getent passwd ssm-user
   sudo osmanthus policy monitor add "$(id -u ssm-user)" --shell /bin/bash
   ```

   Replace `ssm-user` and `/bin/bash` with the actual account and current shell.
   The real shell must be a root-owned executable file and must not be
   group/world writable.
   The command records the original shell and changes the account login shell to
   `/usr/bin/osmanthus-shell`.

4. Confirm that a console or recovery path remains available before changing a
   remote entry point.

## Create and use the document

Creating the AWS document changes external account state and is not performed
by package installation. Review the template, then create a Session document
with a repository- and environment-specific name:

```bash
aws ssm create-document \
  --name OsmanthusSessionShell \
  --document-type Session \
  --document-format JSON \
  --content file://ops/ssm/osmanthus-session.json

aws ssm start-session \
  --target INSTANCE_ID \
  --document-name OsmanthusSessionShell
```

Restrict each operator's IAM `ssm:StartSession` permission to this document and
the intended managed instances. Deny operators `ssm:UpdateDocument` and
`ssm:DeleteDocument` for it. Otherwise an operator can select or alter a
Session document that does not start `osmanthus-shell`.

For an AWS CLI operator, the following is a starting policy. Replace every
uppercase placeholder. Keep document administration on a different role; do
not grant this operator `ssm:CreateDocument`, `ssm:UpdateDocument`,
`ssm:UpdateDocumentDefaultVersion`, or `ssm:DeleteDocument` through another
policy. The explicit deny protects the Osmanthus document even if a broader
allow is attached later.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartOnlyOsmanthusSession",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:REGION:ACCOUNT_ID:instance/INSTANCE_ID",
        "arn:aws:ssm:REGION:ACCOUNT_ID:document/OsmanthusSessionShell"
      ]
    },
    {
      "Sid": "OpenOwnSessionDataChannel",
      "Effect": "Allow",
      "Action": "ssmmessages:OpenDataChannel",
      "Resource": "arn:aws:ssm:*:*:session/${aws:userid}-*"
    },
    {
      "Sid": "ResumeOrTerminateOwnSession",
      "Effect": "Allow",
      "Action": [
        "ssm:ResumeSession",
        "ssm:TerminateSession"
      ],
      "Resource": "arn:aws:ssm:*:*:session/${aws:userid}-*"
    },
    {
      "Sid": "ReadSessionTargetStatus",
      "Effect": "Allow",
      "Action": [
        "ssm:GetConnectionStatus",
        "ssm:DescribeInstanceInformation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProtectOsmanthusSessionDocument",
      "Effect": "Deny",
      "Action": [
        "ssm:UpdateDocument",
        "ssm:UpdateDocumentDefaultVersion",
        "ssm:DeleteDocument"
      ],
      "Resource": "arn:aws:ssm:REGION:ACCOUNT_ID:document/OsmanthusSessionShell"
    }
  ]
}
```

Evaluate the operator's effective permissions, including group policies,
permission boundaries, session policies, and organization SCPs. Do not grant a
second `ssm:StartSession` allow for `SSM-SessionManagerRunShell`,
`AWS-StartSSHSession`, port-forwarding documents, or `document/*`: those entry
points do not execute the Osmanthus PTY supervisor. Kernel protected-root
enforcement still applies host-wide, but the Osmanthus shell transcript does
not exist for a bypassing entry point.

The AWS account administrator must also decide whether Session Manager's own
S3 or CloudWatch logging is required. Those settings are separate from Osmanthus's
local `/var/log/osmanthus/audit.jsonl` evidence.

## Verify

Start a new session through the custom document and run:

```bash
printf '%s\n' "$SHELL"
ps -o pid,ppid,user,args -p $$ -p "$PPID"
sudo tail -n 20 /var/log/osmanthus/audit.jsonl
```

Confirm a session start, input/output records, and a session end after logout.
Then test a disposable file both inside and outside a protected root. Do not use
production data for the first test.

AWS references:

- [Configurable shell profiles](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-preferences-shell-config.html)
- [Session document schema](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-schema.html)
- [Session Manager IAM policy examples](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-restrict-access-quickstart.html)
- [Starting a session with a specific document](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-specify-session-document.html)

## Remove the integration

First restore the managed account's original shell:

```bash
sudo osmanthus policy monitor remove "$(id -u ssm-user)"
getent passwd ssm-user
! grep -Fxq /usr/bin/osmanthus-shell /etc/shells
```

The account must show its recorded original shell. If this was the final managed
login shell, the exact `grep` check must also fail. Only then remove or stop
authorizing the custom AWS document. AWS IAM and document changes are external
operations and are not rolled back by the Osmanthus package manager.
