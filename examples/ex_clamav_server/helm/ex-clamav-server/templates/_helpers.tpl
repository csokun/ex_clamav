{{/*
Expand the name of the chart.
*/}}
{{- define "ex-clamav-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "ex-clamav-server.fullname" -}}
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
{{- define "ex-clamav-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ex-clamav-server.labels" -}}
helm.sh/chart: {{ include "ex-clamav-server.chart" . }}
{{ include "ex-clamav-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ex-clamav-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ex-clamav-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "ex-clamav-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ex-clamav-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the database URL from the postgresql subchart values
*/}}
{{- define "ex-clamav-server.databaseUrl" -}}
{{- if .Values.existingDatabaseSecret }}
{{- else }}
{{- $host := printf "%s-postgresql" .Release.Name }}
{{- $port := "5432" }}
{{- $user := .Values.postgresql.auth.username }}
{{- $pass := .Values.postgresql.auth.password }}
{{- $db := .Values.postgresql.auth.database }}
{{- printf "ecto://%s:%s@%s:%s/%s" $user $pass $host $port $db }}
{{- end }}
{{- end }}
