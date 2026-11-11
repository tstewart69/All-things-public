# The dm-adapters / dm-cleanseimport binaries are self-contained .NET ELF
# x86-64 executables, so this image must be linux/amd64. Cloud Build produces
# amd64 by default; if you build locally on an Apple Silicon Mac, pass
# --platform linux/amd64.
# Pinned to bookworm deliberately: the bare `python:3.12-slim` tag has moved on
# to Debian trixie, where the ICU runtime package is libicu76 rather than
# libicu72. Pinning the Debian release keeps the package name below valid
# instead of breaking whenever the upstream tag rolls to a new distro.
FROM python:3.12-slim-bookworm

# ca-certificates: outbound TLS for the sync scripts and the adapters.
# libicu72:       self-contained .NET refuses to start without ICU unless
#                 invariant globalization is enabled.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libicu72 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install deps before copying the rest so dependency layers stay cached when
# only the scripts change.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# The executable bit does not always survive the copy from a macOS checkout.
RUN chmod +x run_assets_pipeline.sh \
             assets_data_manager/linux-x64/assets-adapters-client/dm-adapters \
             assets_data_manager/linux-x64/assets-cleanse-and-import-client/dm-cleanseimport

# Point the pipeline at the container layout instead of the local macOS defaults.
ENV PROJECT_DIR=/app \
    DM_PLATFORM=linux-x64 \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["/app/run_assets_pipeline.sh"]
