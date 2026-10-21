# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=3.4.9
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
# poppler-utils provides pdftoppm, required for the PDF vision processing path
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y curl libvips postgresql-client libyaml-0-2 procps libjemalloc2 poppler-utils \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ARG BUILD_COMMIT_SHA
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    BUILD_COMMIT_SHA=${BUILD_COMMIT_SHA}

# Official Scalable CLI, pinned with architecture-specific release checksums.
# Kept separate from the gem build so updates do not invalidate bundle install.
FROM base AS scalable-cli
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) arch=x86_64; checksum=64aa3b566f52dab82abdb44c9f6c0a82628fbb392aff1450c84894908639acb8 ;; \
      arm64) arch=aarch64; checksum=9e04c6f608bb1ac0ce4fa063f1971dece7a37842cbf1a6a231f497721298a4f8 ;; \
      *) exit 1 ;; \
    esac \
    && curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      "https://github.com/ScalableCapital/scalable-cli/releases/download/v1.1.0/sc-v1.1.0-linux-${arch}-gnu.tar.gz" -o /sc.tar.gz \
    && echo "$checksum  /sc.tar.gz" | sha256sum --check --strict \
    && mkdir /scalable-cli \
    && tar -xzf /sc.tar.gz -C /scalable-cli --strip-components=1 \
    && curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      "https://raw.githubusercontent.com/ScalableCapital/scalable-cli/v1.1.0/LICENSE" -o /scalable-cli/LICENSE \
    && echo 'd17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc  /scalable-cli/LICENSE' | sha256sum --check --strict \
    && /scalable-cli/sc --version

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y build-essential libpq-dev git pkg-config libyaml-dev \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install \
    && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git \
    && bundle exec bootsnap precompile --gemfile -j 0

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile -j 0 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage for app image
FROM base

COPY --from=scalable-cli /scalable-cli/sc /usr/local/bin/sc
COPY --from=scalable-cli /scalable-cli/LICENSE /usr/local/share/scalable-cli/LICENSE
COPY --from=scalable-cli /scalable-cli/THIRD_PARTY_NOTICES.md /usr/local/share/scalable-cli/THIRD_PARTY_NOTICES.md
COPY --from=scalable-cli /scalable-cli/third_party_licenses /usr/local/share/scalable-cli/third_party_licenses

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
