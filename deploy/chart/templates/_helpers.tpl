{{/* A published CloudBreak image: cloudbreak.image (list $ "real-core"). */}}
{{- define "cloudbreak.image" -}}
{{- $root := index . 0 -}}
image: {{ printf "%s/%s:%s" $root.Values.images.registry (index . 1) $root.Values.images.tag | quote }}
imagePullPolicy: {{ $root.Values.images.pullPolicy | default (ternary "Always" "IfNotPresent" (eq $root.Values.images.tag "main")) }}
{{- end -}}

{{/* real-core's Postgres (templates/postgres.yaml). */}}
{{- define "cloudbreak.databaseUrl" -}}
postgres://cloudbreak:cloudbreak@postgres:5432/cloudbreak
{{- end -}}

{{/* Gate on the Temporal frontend instead of crash-looping into backoff. */}}
{{- define "cloudbreak.waitTemporal" -}}
- name: wait-temporal
  image: {{ .Values.images.temporal }}
  command:
    - sh
    - -c
    - until temporal operator cluster health --address temporal:7233; do sleep 2; done
{{- end -}}
