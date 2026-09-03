# deploy/Dockerfile — WebMCP Foundry + Ledgerly in one container (two ports).
FROM julia:1.12
WORKDIR /srv/webmcp-foundry
COPY . .
RUN mkdir -p data
EXPOSE 8090 8091
# FOUNDRY_URL: the public origin judges reach the console on (the app page fetches the manifest there)
ENV FOUNDRY_URL=https://foundry.example.com
CMD ["sh", "-c", "julia bin/foundry.jl --foundry-url \"$FOUNDRY_URL\""]
