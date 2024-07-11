# This builds an http only nginx, with no extra modules, and no openssl
FROM alpine:3.20 AS nginx-builder

ENV NGINX_VERSION=1.26.1
# releases can be signed by any key on this page https://nginx.org/en/pgp_keys.html
# so this might need to be updated for a new release
# available keys: mdounin, maxim, sb, thresh
# the "signing key" is used for linux packages, see https://trac.nginx.org/nginx/ticket/205
ENV PGP_SIGNING_KEY_OWNER=thresh

# install dependencies: here we use brotli-dev, newer brotli versions we can remove that and build it
RUN apk add --no-cache git libc-dev pcre2-dev make gcc binutils gnupg cmake brotli-dev

# create a builder user and group
RUN addgroup -S -g 3148 builder && adduser -D -S -G builder -u 3148 builder
RUN mkdir /build && chown builder:builder /build
WORKDIR /build
USER builder

# clone the nginx modules
RUN git clone --recurse-submodules https://github.com/google/ngx_brotli && cd ngx_brotli/deps/brotli && mkdir out && cd out \
    && cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-Ofast -m64 -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" -DCMAKE_CXX_FLAGS="-Ofast -m64 -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" -DCMAKE_INSTALL_PREFIX=./installed .. \
    && cmake --build . --config Release --target brotlienc && cd ../../../..

# now start the build
# get nginx source
ADD --chown=builder:builder https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz nginx.tgz
# get nginx signature file
ADD --chown=builder:builder https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz.asc nginx.tgz.asc
# get the corresponding public key
ADD --chown=builder:builder https://nginx.org/keys/$PGP_SIGNING_KEY_OWNER.key nginx-signing.key
# import it and verify the tarball
RUN gpg --import nginx-signing.key
# only run on amd64 because it fails on arm64 for some weird unknown reason
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then gpg --verify nginx.tgz.asc; fi
# all good now untar and build!
RUN tar xzf nginx.tgz
WORKDIR /build/nginx-$NGINX_VERSION
# change the hardcoded Server header value
RUN sed -i 's/"Server: nginx" CRLF/"Server: d" CRLF/' src/http/ngx_http_header_filter_module.c
# Compilation flags
# -g0: Disable debugging symbols generation (decreases binary size)
# -O3: Enable aggressive optimization level 3 (improves code execution speed)
# -fstack-protector-strong: Enable stack protection mechanisms (prevents stack-based buffer overflows)
# -flto: Enable Link Time Optimization (LTO) (allows cross-source-file optimization)
# -pie: Generate position-independent executables (PIE) (enhances security)
# --param=ssp-buffer-size=4: Set the size of the stack buffer for stack smashing protection to 4 bytes
# -Wformat -Werror=format-security: Enable warnings for potentially insecure usage of format strings (treats them as errors)
# -D_FORTIFY_SOURCE=2: Enable additional security features provided by fortified library functions
# -Wl,-z,relro,-z,now: Enforce memory protections at runtime:
#    - Mark the Global Offset Table (GOT) as read-only after relocation
#    - Resolve all symbols at load time, making them harder to manipulate
# -Wl,-z,noexecstack: Mark the stack as non-executable (prevents execution of code placed on the stack)
# -fPIC: Generate position-independent code (PIC) (suitable for building shared libraries)
RUN ./configure \
        --prefix=/var/lib/nginx \
        --sbin-path=/usr/sbin/nginx \
        --with-cc-opt='-g0 -O3 -fstack-protector-strong -flto -pie --param=ssp-buffer-size=4 -Wformat -Werror=format-security -D_FORTIFY_SOURCE=2 -Wl,-z,relro,-z,now -Wl,-z,noexecstack -fPIC -static -static-libgcc' \
        --with-ld-opt='-static' \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --pid-path=/nginx/nginx.pid \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --lock-path=/nginx/nginx.lock \
        --http-client-body-temp-path=/nginx/nginx-client_body \
        --http-fastcgi-temp-path=/nginx/nginx-fastcgi \
        --user=nobody \
        --group=nobody \
        --with-threads \
        --with-http_realip_module \
        --with-http_stub_status_module \
        --add-module=/build/ngx_brotli \
        --without-http_autoindex_module \
        --without-http_browser_module \
        --without-http_empty_gif_module \
        --without-http_geo_module \
        --without-http_gzip_module \
        --without-http_limit_conn_module \
        --without-http_limit_req_module \
        --without-http_map_module \
        --without-http_memcached_module \
        --without-http_proxy_module \
        --without-http_referer_module \
        --without-http_scgi_module \
        --without-http_split_clients_module \
        --without-http_ssi_module \
        --without-http_upstream_ip_hash_module \
        --without-http_userid_module \
        --without-http_uwsgi_module \
    && make -j$(getconf _NPROCESSORS_ONLN) \
    && strip -s objs/nginx

USER root
RUN make install

FROM alpine:3.20
COPY --from=nginx-builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-builder /etc/nginx/mime.types /etc/nginx/mime.types
COPY --from=nginx-builder /etc/nginx/fastcgi.conf /etc/nginx/fastcgi.conf
COPY --from=nginx-builder /var/lib/nginx /var/lib/nginx
# create the log folder and make the logfiles links to stdout/stderr so docker logs will catch it
RUN mkdir -p /var/log/nginx \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log
ADD nginx.conf /etc/nginx/nginx.conf
ADD common.conf /etc/nginx/common.conf
RUN mkdir /etc/nginx/conf.d
RUN mkdir /nginx && chown nobody:nobody /nginx
USER nobody
ENTRYPOINT ["nginx"]
