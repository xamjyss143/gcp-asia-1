FROM nginx:alpine

RUN apk add --no-cache bash curl

COPY nginx.conf /etc/nginx/nginx.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh

# Add default website page
COPY index.html /usr/share/nginx/html/index.html

RUN chmod +x /docker-entrypoint.sh

EXPOSE 8080
CMD ["/docker-entrypoint.sh"]
