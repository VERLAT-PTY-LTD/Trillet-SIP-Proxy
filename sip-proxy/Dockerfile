FROM golang:1.20-alpine AS builder

WORKDIR /app
COPY . .
RUN go mod download
RUN go build -o sip-proxy .

FROM alpine:latest
RUN apk --no-cache add ca-certificates

WORKDIR /app
COPY --from=builder /app/sip-proxy .

EXPOSE 5060/udp
EXPOSE 5060/tcp

ENTRYPOINT ["/app/sip-proxy"] 