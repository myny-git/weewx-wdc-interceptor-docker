FROM python:3.11-slim-bookworm

ARG WEEWX_VERSION="5.1.0"
ARG WDC_VERSION="v3.5.1"
ARG WEEWX_FORECAST_VERSION="3.5"
ARG INTERCEPTOR_VERSION="v1.0.0"
ARG INTERCEPTOR_REPO="tfilo/weewx-interceptor"
ARG WEEWX_UID=2749

# Metadata labels (OCI)
LABEL org.opencontainers.image.title="WeeWX with WDC + Interceptor" \
    org.opencontainers.image.description="Containerized WeeWX ${WEEWX_VERSION} incl. WDC ${WDC_VERSION}, Interceptor ${INTERCEPTOR_VERSION}, Forecast, MQTT, XAggs, GTS" \
    org.opencontainers.image.authors="David Baetge <david.baetge@gmail.com>, Kris Myny" \
    org.opencontainers.image.source="https://github.com/myny-git/weewx-wdc-interceptor-docker" \
    org.opencontainers.image.documentation="https://github.com/${INTERCEPTOR_REPO}/releases/tag/${INTERCEPTOR_VERSION}" \
    org.opencontainers.image.licenses="GPL-3.0-or-later"
ARG PAHO_MQTT_VERSION="1.6.1"

ENV WEEWX_HOME="/home/weewx-data" \
    WEEWX_VERSION=${WEEWX_VERSION} \
    WDC_VERSION=${WDC_VERSION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 9877

COPY src/start.sh /start.sh
RUN chmod +x /start.sh

# Base OS deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends busybox-syslogd wget unzip zip ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

# Create user
RUN addgroup --system --gid ${WEEWX_UID} weewx \
 && adduser --system --uid ${WEEWX_UID} --ingroup weewx weewx

# (Optional) timezone can be mounted/overridden at runtime; default stays UTC

WORKDIR /tmp

# Download extensions (single layer)
RUN set -eux; \
    wget -nv -O weewx-interceptor.zip "https://github.com/${INTERCEPTOR_REPO}/archive/refs/tags/${INTERCEPTOR_VERSION}.zip"; \
    wget -nv -O weewx-wdc-${WDC_VERSION}.zip "https://github.com/Daveiano/weewx-wdc/releases/download/${WDC_VERSION}/weewx-wdc-${WDC_VERSION}.zip"; \
    wget -nv -O weewx-forecast.zip "https://github.com/chaunceygardiner/weewx-forecast/releases/download/v${WEEWX_FORECAST_VERSION}/weewx-forecast-${WEEWX_FORECAST_VERSION}.zip"; \
    wget -nv -O weewx-mqtt.zip "https://github.com/matthewwall/weewx-mqtt/archive/master.zip"; \
    wget -nv -O weewx-xaggs.zip "https://github.com/tkeffer/weewx-xaggs/archive/master.zip"; \
    wget -nv -O weewx-GTS.zip "https://github.com/roe-dl/weewx-GTS/archive/master.zip"; \
    mkdir /tmp/weewx-wdc; \
    unzip -q /tmp/weewx-wdc-${WDC_VERSION}.zip -d /tmp/weewx-wdc; \
    mkdir -p /opt/weewx-ext; \
    mv /tmp/weewx-interceptor.zip /tmp/weewx-wdc-${WDC_VERSION}.zip /tmp/weewx-forecast.zip /tmp/weewx-mqtt.zip /tmp/weewx-xaggs.zip /tmp/weewx-GTS.zip /tmp/weewx-wdc /opt/weewx-ext/

WORKDIR /tmp

WORKDIR ${WEEWX_HOME}

# Virtualenv + core installs
RUN python -m venv ${WEEWX_HOME}/weewx-venv \
 && . ${WEEWX_HOME}/weewx-venv/bin/activate \
 && pip install --upgrade pip \
 && pip install --no-cache-dir "paho-mqtt==${PAHO_MQTT_VERSION}" "weewx==${WEEWX_VERSION}" "six>=1.16,<2"

# Runtime will create station + install extensions; seed data dir only
RUN mkdir -p ${WEEWX_HOME}/data

# Clean up build artifacts
RUN rm -rf /tmp/* ~/.cache/pip

VOLUME [ "${WEEWX_HOME}/public_html" ]
VOLUME [ "${WEEWX_HOME}/archive" ]

# Simple healthcheck: process exists
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 CMD pgrep -f weewxd >/dev/null || exit 1

ENTRYPOINT [ "/start.sh" ]
