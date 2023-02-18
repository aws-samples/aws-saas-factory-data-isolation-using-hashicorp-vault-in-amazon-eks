    [${PROFILE}]
    {{- with secret "aws/sts/${PROFILE}" }}
    aws_access_key_id={{ .Data.access_key }}
    aws_secret_access_key={{ .Data.secret_key }}
    aws_session_token={{ .Data.security_token }}
    {{ end }}