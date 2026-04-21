FROM debian:12

# Install build dependencies
RUN apt-get update && apt-get install -y \
    autoconf \
    automake \
    build-essential \
    cmake \
    git \
    libcurl4-openssl-dev \
    libtool \
    libmosquitto-dev \
    libsqlite3-dev \
    libssl-dev \
    libz-dev \
    pkg-config \
    valgrind \
    psmisc \
    lcov \
    openssh-server

# Environment variables from Yocto SDK for default compiler flags
ENV CFLAGS=" -Os -pipe -g -feliminate-unused-debug-types "
ENV CXXFLAGS=" -Os -pipe -g -feliminate-unused-debug-types "
ENV LDFLAGS="-Wl,-O1 -Wl,--hash-style=gnu -Wl,--as-needed"

WORKDIR /work

# obuspa — built from local source (patched group_get_vector.c for per-entry error codes)
ARG OBUSPA_CACHE_BUST=1
COPY obuspa /work/obuspa
RUN cd /work/obuspa && \
    autoreconf --force --install && \
    mkdir -p build && \
    cd build && \
    ../configure \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        --prefix="/usr/local" \
        --disable-websockets \
        && \
    make install-strip -j && \
    rm -rf /work/obuspa

# rbus
ARG RBUS_CACHE_BUST=1
COPY rbus /work/rbus
RUN cd /work/rbus && \
    cmake -B build \
        -DCMAKE_INSTALL_PREFIX="/usr/local" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_C_FLAGS="-I/usr/local/include" \
        -DBUILD_FOR_DESKTOP=ON \
        -DMSG_ROUNDTRIP_TIME=ON \
        -DBUILD_RBUS_SAMPLE_APPS=ON \
        -DBUILD_RBUS_TEST_APPS=OFF  && \
    make VERBOSE=1 -C build install && \
    cp /work/rbus/build/deps/src/msgpack/libmsgpackc.so* /usr/local/lib/ && \
    cp /work/rbus/build/deps/src/cjson/libcjson.so* /usr/local/lib/ && \
    rm -rf /work/rbus

# usp-pa-vendor-rdk
COPY usp-pa-vendor-rdk /work/usp-pa-vendor-rdk
RUN cd /work/usp-pa-vendor-rdk/src/vendor && \
    (make distclean 2>/dev/null || true) && \
    autoreconf --force --install && \
    mkdir -p build && \
    cd build && \
    ../configure \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        --prefix="/usr/local" && \
    make install-strip -j && \
    rm -rf /work/usp-pa-vendor-rdk

# Create symlink for UspPA as requested by user
RUN ln -s /usr/local/bin/obuspa /usr/local/bin/UspPA

# Build test providers (rbus and obuspa headers must be installed first)
COPY usp-pa-vendor-rdk/de_dm_notify/rbusMassProvider.c /tmp/rbusMassProvider.c
COPY usp-pa-vendor-rdk/de_dm_notify/rbusTestProvider.c /tmp/rbusTestProvider.c
RUN gcc -Os -o /usr/local/bin/rbusMassProvider /tmp/rbusMassProvider.c \
        -I/usr/local/include/rbus -L/usr/local/lib -lrbus && \
    gcc -Os -o /usr/local/bin/rbusTestProvider /tmp/rbusTestProvider.c \
        -I/usr/local/include/rbus -L/usr/local/lib -lrbus && \
    rm /tmp/rbusMassProvider.c /tmp/rbusTestProvider.c

# Copy test suite scripts into /work/
RUN mkdir -p /work
COPY usp-pa-vendor-rdk/de_dm_notify/unified_test_suite.sh /work/unified_test_suite.sh
RUN chmod +x /work/unified_test_suite.sh && \
    touch /work/provider.log /work/test_report.txt

COPY usp-pa-vendor-rdk/de_dm_notify/start_services.sh /usr/local/bin/start_services.sh
RUN chmod +x /usr/local/bin/start_services.sh

# Ensure log files exist for tail
RUN touch /var/log/rtrouted.log /var/log/obuspa.log

# Ensure etc directory exists for vendor config
RUN mkdir -p /etc/usp-pa && chmod 777 /etc/usp-pa

# Ensure libraries are found
RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf && ldconfig

# Configure SSH
RUN mkdir /var/run/sshd && \
    echo 'root:root' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 22

ENTRYPOINT [ "/usr/local/bin/start_services.sh" ]
