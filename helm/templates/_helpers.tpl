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

{{/*
JVM trust settings from config (CU-86bcqtb6w) -- see jvmSecurity in values.yaml.
Every lookup goes through `.Values.jvmSecurity | default dict`, so a release
upgraded with --reuse-values from a chart without the block renders as disabled.

True (non-empty) when the feature is on.
*/}}
{{- define "pdfreactor.jvmSecurity.enabled" -}}
{{- $js := .Values.jvmSecurity | default dict -}}
{{- if $js.enabled }}true{{ end -}}
{{- end }}

{{/*
Name of the ConfigMap carrying blocked.certs.extra, distrusted.anchors and java.security.
*/}}
{{- define "pdfreactor.jvmSecurity.configMapName" -}}
{{- printf "%s-jvm-security" (include "pdfreactor.jvmSecurity.namePrefix" .) -}}
{{- end }}

{{/*
Name of the optional operator overlay ConfigMap. Helm never renders it, so an
emergency edit there survives deploys; the init container merges it over ours.
*/}}
{{- define "pdfreactor.jvmSecurity.localConfigMapName" -}}
{{- printf "%s-jvm-security-local" (include "pdfreactor.jvmSecurity.namePrefix" .) -}}
{{- end }}

{{/*
The fullname, cut short enough that the longer suffix ("-jvm-security-local")
still fits in 63 characters. Both names use it, so they always share a prefix
and stay distinct; truncating after appending would let the suffix collapse.
*/}}
{{- define "pdfreactor.jvmSecurity.namePrefix" -}}
{{- include "pdfreactor.fullname" . | trunc (sub 63 (len "-jvm-security-local") | int) | trimSuffix "-" -}}
{{- end }}

{{/*
First init container: builds the validated snapshot (cacerts, blocked.certs,
java.security) in the jvm-security-merged emptyDir from the ConfigMap. The
script is files/jvm-security-init.sh, kept byte-identical to the campaign's
reference copy. It deliberately takes no env/envFrom from the app ConfigMap,
so the app's JVM options don't reach these JVMs.
*/}}
{{- define "pdfreactor.jvmSecurity.initContainer" -}}
{{- $js := .Values.jvmSecurity | default dict -}}
- name: jvm-security
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  env:
  - name: EXPECTED_JAVA_HOME
    value: {{ $js.javaHome | quote }}
  command:
  - sh
  - -ec
  - |
    {{- .Files.Get "files/jvm-security-init.sh" | nindent 4 }}
  volumeMounts:
  - name: jvm-security
    mountPath: /etc/bluestep/jvm-security-src
    readOnly: true
  - name: jvm-security-local
    mountPath: /etc/bluestep/jvm-security-local
    readOnly: true
  - name: jvm-security-merged
    mountPath: /merged
  resources:
    {{- toYaml $js.initResources | nindent 4 }}
{{- end }}

{{/*
Mounts for every container that runs a JVM: the validated snapshot only,
never the ConfigMap itself.
*/}}
{{- define "pdfreactor.jvmSecurity.volumeMounts" -}}
{{- $js := .Values.jvmSecurity | default dict -}}
{{- $sec := printf "%s/lib/security" (trimSuffix "/" $js.javaHome) -}}
- name: jvm-security-merged
  mountPath: /etc/bluestep/jvm-security
  readOnly: true
- name: jvm-security-merged
  mountPath: {{ $sec }}/blocked.certs
  subPath: blocked.certs
  readOnly: true
- name: jvm-security-merged
  mountPath: {{ $sec }}/cacerts
  subPath: cacerts
  readOnly: true
{{- end }}

{{/*
Pod volumes backing the init container and the mounts above.
*/}}
{{- define "pdfreactor.jvmSecurity.volumes" -}}
- name: jvm-security
  configMap:
    name: {{ include "pdfreactor.jvmSecurity.configMapName" . }}
- name: jvm-security-local
  configMap:
    name: {{ include "pdfreactor.jvmSecurity.localConfigMapName" . }}
    optional: true
- name: jvm-security-merged
  emptyDir:
    sizeLimit: 2Mi
{{- end }}

{{/*
JDK_JAVA_OPTIONS for the app container. start.sh launches the JVM with the
`java` launcher, which reads it. Single `=` layers the snapshot over the JDK's
java.security instead of replacing it. Appends to any JDK_JAVA_OPTIONS set
through configmap.data, which this explicit env entry would otherwise shadow.
*/}}
{{- define "pdfreactor.jvmSecurity.jdkJavaOptions" -}}
{{- $existing := default "" (get .Values.configmap.data "JDK_JAVA_OPTIONS") -}}
{{- trim (printf "%s -Djava.security.properties=/etc/bluestep/jvm-security/java.security" $existing) -}}
{{- end }}
