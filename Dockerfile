ARG EAP_IMAGE_REF
FROM ${EAP_IMAGE_REF}
USER root
RUN python3 --version
COPY --chown=irisowner:irisowner src /opt/storm/src
COPY --chown=irisowner:irisowner fixtures /opt/storm/fixtures
COPY --chown=irisowner:irisowner init.script /opt/storm/init.script
USER irisowner
