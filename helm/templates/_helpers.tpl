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

Deliberately has NO default. This chart lives in a public repo, and a committed
placeholder shipped straight to production once already: the live ConfigMap in
b6p-system ran "always-replace-this-secret" -- the same string published here --
and /service/monitor/server answered that key over the public internet. A
`required` that breaks the render is the cheaper failure. See CU-86bbqrrrt.

Supply it at install/upgrade time, from somewhere outside this repo:
  helm upgrade ... --set configmap.data.PDFREACTOR_ADMINKEY=<key>

Not sourced from ExternalSecrets, deliberately. The probes interpolate this
value into their httpGet path at *render* time, and a Secret cannot be read
then. Wiring the app's env from ESO while the probes render some other value
would hand the liveness probe a key the server rejects -- a guaranteed
crashloop on a service the licence pins to a single replica. Note also that
secrets.yaml targets `<fullname>-license`, which is mounted as a file at
/ro/config: an ESO entry for this key would land it in the licence mount and
never reach the environment at all.
*/}}
{{- define "pdfreactor.adminKey" -}}
{{- required "configmap.data.PDFREACTOR_ADMINKEY must be set explicitly -- this chart is public and ships no default admin key (CU-86bbqrrrt)" .Values.configmap.data.PDFREACTOR_ADMINKEY -}}
{{- end }}
