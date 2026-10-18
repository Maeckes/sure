ARG RUBY_VERSION=3.4.9
FROM ruby:${RUBY_VERSION}-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# libvips42 supports ActiveStorage image variants through image_processing/ruby-vips
# for existing profile/avatar images. AccountStatement.original_file only stores
# PDF/CSV/XLSX originals, but the devcontainer needs this broader image stack.
# poppler-utils provides pdftoppm, required for the PDF vision processing path.
RUN apt-get update -qq \
  && apt-get -y install --no-install-recommends \
    apt-utils \
    build-essential \
    curl \
    git \
    imagemagick \
    iproute2 \
    libvips42 \
    libpq-dev \
    libyaml-dev \
    libyaml-0-2 \
    openssh-client \
    postgresql-client \
    python3 \
    python3-venv \
    poppler-utils \
    procps \
    vim \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN gem install bundler foreman

COPY services/fints_worker/requirements.lock /tmp/fints-requirements.lock
RUN python3 -m venv /opt/fints-venv \
  && /opt/fints-venv/bin/pip install --no-cache-dir --no-deps -r /tmp/fints-requirements.lock \
  && rm /tmp/fints-requirements.lock

ENV FINTS_PYTHON=/opt/fints-venv/bin/python

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /workspace
