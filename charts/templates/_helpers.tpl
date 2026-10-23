{{/* Use the dependency name unless the operator changes it. */}}
{{- define "jenkins-wrapper.upstreamName" -}}
{{- default "jenkins" .Values.jenkins.nameOverride -}}
{{- end -}}

{{/* Match the upstream fullname so wrapper resources use the same names. */}}
{{- define "jenkins-wrapper.upstreamFullname" -}}
{{- if .Values.jenkins.fullnameOverride -}}
{{- .Values.jenkins.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "jenkins-wrapper.upstreamName" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Use the label watched by the upstream configuration reload sidecar. */}}
{{- define "jenkins-wrapper.jcascLabel" -}}
{{- printf "%s-jenkins-config" (include "jenkins-wrapper.upstreamFullname" .) -}}
{{- end -}}
