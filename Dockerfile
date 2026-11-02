FROM python:3.11-slim-bookworm

ARG WEEWX_VERSION="5.5.2"
ARG WDC_VERSION="v3.5.1"
ARG WEEWX_FORECAST_VERSION="5.4"
ARG INTERCEPTOR_VERSION="v1.0.1"
ARG INTERCEPTOR_REPO="tfilo/weewx-interceptor"
ARG MQTT_REF="a182707d12a5abc778eb7756856e1be2047627f9"
ARG XAGGS_REF="d36145689b6d4bd363a792432df94215d69f5026"
ARG GTS_REF="v1.2"
ARG XCUMULATIVE_REF="a5e412d22464b95d74d2cada02efb9bddda0db64"
ARG XCUMULATIVE_REPO="hoetzgit/weewx-xcumulative"
ARG PAHO_MQTT_VERSION="1.6.1"
ARG WEEWX_UID=2749

LABEL org.opencontainers.image.title="WeeWX with WDC + Interceptor" \
    org.opencontainers.image.version="${WEEWX_VERSION}" \
    org.opencontainers.image.description="WeeWX ${WEEWX_VERSION}, WDC ${WDC_VERSION}, Interceptor ${INTERCEPTOR_VERSION}, Forecast ${WEEWX_FORECAST_VERSION}, MQTT, XAggs and GTS" \
    org.opencontainers.image.authors="David Baetge <david.baetge@gmail.com>, Kris Myny" \
    org.opencontainers.image.source="https://github.com/myny-git/weewx-wdc-interceptor-docker" \
    org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV WEEWX_HOME="/home/weewx-data" \
    WEEWX_VERSION=${WEEWX_VERSION} \
    WDC_VERSION=${WDC_VERSION} \
    WEEWX_FORECAST_VERSION=${WEEWX_FORECAST_VERSION} \
    PATH="/opt/weewx-venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY constraints.txt /opt/weewx-constraints.txt
RUN apt-get update \
 && apt-get install -y --no-install-recommends busybox-syslogd wget ca-certificates tzdata procps \
 && rm -rf /var/lib/apt/lists/* \
 && addgroup --system --gid ${WEEWX_UID} weewx \
 && adduser --system --uid ${WEEWX_UID} --ingroup weewx weewx \
 && python -m venv /opt/weewx-venv \
 && pip install --no-cache-dir --constraint /opt/weewx-constraints.txt "paho-mqtt==${PAHO_MQTT_VERSION}" "weewx==${WEEWX_VERSION}"

COPY src/ /usr/local/lib/weewx-container/
RUN chmod +x /usr/local/lib/weewx-container/start.sh

WORKDIR /tmp/extensions
RUN set -eu; \
    wget -nv -O interceptor.zip "https://github.com/${INTERCEPTOR_REPO}/archive/refs/tags/${INTERCEPTOR_VERSION}.zip"; \
    wget -nv -O wdc.zip "https://github.com/Daveiano/weewx-wdc/releases/download/${WDC_VERSION}/weewx-wdc-${WDC_VERSION}.zip"; \
    wget -nv -O forecast.zip "https://github.com/chaunceygardiner/weewx-forecast/releases/download/v${WEEWX_FORECAST_VERSION}/weewx-forecast.zip"; \
    wget -nv -O mqtt.zip "https://github.com/matthewwall/weewx-mqtt/archive/${MQTT_REF}.zip"; \
    wget -nv -O xaggs.zip "https://github.com/tkeffer/weewx-xaggs/archive/${XAGGS_REF}.zip"; \
    wget -nv -O GTS.zip "https://github.com/roe-dl/weewx-GTS/archive/${GTS_REF}.zip"; \
    wget -nv -O xcumulative.zip "https://github.com/${XCUMULATIVE_REPO}/archive/${XCUMULATIVE_REF}.zip"; \
    python /usr/local/lib/weewx-container/prepare.py /tmp/extensions; \
    pip freeze > /opt/weewx-seed/python-packages.txt; \
    rm -rf /tmp/extensions

WORKDIR ${WEEWX_HOME}
RUN mkdir -p data archive public_html
VOLUME ["/home/weewx-data/public_html", "/home/weewx-data/archive"]
EXPOSE 9877

HEALTHCHECK --interval=2m --timeout=10s --start-period=2m --retries=3 CMD pgrep -f '^/opt/weewx-venv/bin/python.*weewxd' >/dev/null || exit 1
ENTRYPOINT ["/usr/local/lib/weewx-container/start.sh"]
