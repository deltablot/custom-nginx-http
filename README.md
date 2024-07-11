# custom-http-nginx

This Docker image builds a custom nginx, stripped of many features.

Its purpose is to be a barebone HTTP server, no HTTPS, no HTTP/2, perfect for serving static files behind a reverse proxy.

It runs as the `nobody` user.

## Usage

Use it as a base for a website

~~~bash
FROM deltablot/custom-http-nginx
COPY site/ /app
COPY site.conf /etc/nginx/conf.d
~~~

Example site.conf

~~~conf
server {
    server_name your-domain.tld;

    listen 8080;
    root /app;
    index index.html;

    # restrict allowed methods
    if ($request_method !~ ^(GET|HEAD)$) {
        return 405;
    }

    error_page 404 /404.html;

    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options nosniff;
    add_header Content-Security-Policy "default-src 'self'; style-src 'unsafe-inline'; object-src 'none';";
    add_header Strict-Transport-Security "max-age=31536100; includeSubDomains; preload";

    # redirect server error pages to the static page /50x.html
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }

    location / {
        try_files $uri $uri/ =404;
    }
    include common.conf;
}
