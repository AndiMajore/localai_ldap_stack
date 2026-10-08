Optional: put extra CA certificates here (PEM, e.g. `company-ca.crt`).

LocalAI trusts them in addition to the system bundle. That is only needed when Apache's
certificate for `auth.<domain>` comes from an internal company CA, because LocalAI connects to
`https://auth.<domain>` through Apache. Certificates from public CAs work without anything here.
