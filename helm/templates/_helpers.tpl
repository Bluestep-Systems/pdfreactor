{{/*
Expand the name of the chart.
*/}}
{{- define "pdfreactor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pdfreactor.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pdfreactor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pdfreactor.labels" -}}
helm.sh/chart: {{ include "pdfreactor.chart" . }}
app.kubernetes.io/part-of: bluestep
{{ include "pdfreactor.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pdfreactor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pdfreactor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "pdfreactor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pdfreactor.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
The PDFReactor admin key, which gates the /service/monitor admin surface.

It is a SECRET, and it lives in Bitwarden Secrets Manager as PDFREACTOR_ADMIN_KEY.
ESO syncs it into the "<fullname>-license" Secret under the key PDFREACTOR_ADMINKEY;
deployment.yaml consumes it as an env var via secretKeyRef, never from the ConfigMap.

This chart is public, so it ships no default for it in either mode. A committed
placeholder reached production verbatim once already: the live ConfigMap in
b6p-system ran "always-replace-this-secret" -- the same string published here --
and /service/monitor/server answered that key over the public internet. See
CU-86bbqrrrt.

Why the probes are `exec` and not `httpGet`: PDFReactor takes the admin key as a
query parameter, so an httpGet probe has to bake the key into the Deployment's
probe path at *render* time. That makes the value plaintext in the pod spec and
in the Helm release, which defeats sourcing it from a Secret at all -- and no
Secret can be read at render time to fill it. An exec probe expands
$PDFREACTOR_ADMINKEY inside the container at *run* time, so the pod spec carries
only the variable name. Same endpoint, same key, same pass/fail semantics as the
httpGet probes it replaces; only the moment of expansion changes.
*/}}

{{/*
Admin key for the self-managed Secret path (externalSecrets.enabled=false).
Required: an empty admin key is not a safe default for a service whose monitor
surface is reachable from the public internet.
*/}}
{{- define "pdfreactor.adminKey" -}}
{{- required "adminkey must be set explicitly when externalSecrets.enabled=false -- this chart is public and ships no default admin key (CU-86bbqrrrt)" .Values.adminkey -}}
{{- end }}

{{/*
Fail the render if ESO is enabled but is not actually syncing the admin key.
Without this the mistake surfaces only at rollout, as a pod stuck in
CreateContainerConfigError on a single-replica service.
*/}}
{{- define "pdfreactor.validateAdminKeySource" -}}
{{- if .Values.externalSecrets.enabled -}}
{{- $found := false -}}
{{- range .Values.externalSecrets.data -}}
{{- if eq .secretKey "PDFREACTOR_ADMINKEY" -}}{{- $found = true -}}{{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail "externalSecrets.data must include an entry with secretKey PDFREACTOR_ADMINKEY (remoteKey PDFREACTOR_ADMIN_KEY) -- the deployment reads the admin key from that Secret (CU-86bbqrrrt)" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The liveness/startup probe command. One definition, used by both probes, so they
can never drift apart. --max-time sits just under the probes' timeoutSeconds so
a hung server fails the probe deterministically rather than racing the kubelet.
*/}}
{{- define "pdfreactor.monitorProbe" -}}
- /bin/bash
- -c
- 'curl -sf --max-time 4 -o /dev/null "http://127.0.0.1:9423/service/monitor/server?adminKey=${PDFREACTOR_ADMINKEY}"'
{{- end }}
