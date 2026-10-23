FROM jenkins/jenkins:2.580.1-jdk25@sha256:42fc298cdafa2683dddde9a7ccdce4058f771b1ec56c2423dbfca82f010a455f

COPY --chown=jenkins:jenkins plugins.lock.txt /usr/share/jenkins/ref/plugins.lock.txt

# Download at build time, never while the controller starts.
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.lock.txt --latest false
