# Development IRIS image for __NAME__: the stock image plus namespace __NS__ (__NS__-CODE and
# __NS__-DATA). Application code is not baked in: scripts/load.sh copies the source directories
# into the container at run time, so code changes never need an image rebuild.
ARG IMAGE=containers.intersystems.com/intersystems/iris-community:__IRIS_TAG__
FROM ${IMAGE}

USER root
RUN mkdir -p /opt/irisapp /opt/irisbuild && chown irisowner:irisowner /opt/irisapp /opt/irisbuild
USER irisowner

COPY --chown=irisowner:irisowner iris.script Installer.cls merge.cpf /opt/irisbuild/

# A license key is mounted at run time, so the build runs key-less, which is fine for setup.
# iris.script ends with a non-zero status if the namespace is missing, failing the build.
RUN iris start IRIS \
    && iris session IRIS < /opt/irisbuild/iris.script \
    && iris stop IRIS quietly
