# A stable signing certificate for rebuilds

macOS ties the Accessibility grant to an app's code signature. Ad-hoc
signing (`codesign -s -`) produces a new identity on every build, so every
rebuild of YTT would send you back to System Settings. A self-signed
certificate fixes that: same identity every build, grant kept.

`build.sh` looks for a certificate named `YTT Dev` and uses it when found.

Putting the certificate in its own keychain avoids a password prompt at
every build. These commands do it all from a terminal, no Keychain Access
clicking:

```sh
cd "$(mktemp -d)"

cat > ytt.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = YTT Dev
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout ytt.key -out ytt.crt -config ytt.cnf
openssl pkcs12 -export -legacy -inkey ytt.key -in ytt.crt \
  -out ytt.p12 -passout pass:ytt -name "YTT Dev"

KC="$HOME/Library/Keychains/ytt-signing.keychain-db"
security create-keychain -p "choose-any-password" "$KC"
security set-keychain-settings "$KC"            # never auto-lock
security import ytt.p12 -k "$KC" -P ytt -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "choose-any-password" "$KC"
security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC"
security add-trusted-cert -p codeSign -k "$KC" ytt.crt

rm -f ytt.key ytt.p12
security find-identity -v -p codesigning | grep "YTT Dev"
```

Then rebuild and reinstall. Because the app identity changed once more,
clear the old permission record and grant Accessibility one last time:

```sh
tccutil reset Accessibility local.ytt.menubar
open /Applications/YTT.app
```

From then on rebuilds keep the grant.

If the certificate ends up in the login keychain instead (for example after
importing it with Keychain Access), macOS asks for your login password on
the first build. Click "Always Allow" and it stops asking.
