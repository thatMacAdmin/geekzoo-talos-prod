# Plane deployment notes

Plane uses external data services and secrets. Before reconciling the Plane
stack, create these AWS SSM Parameter Store entries as JSON objects.

## Database and backups

`/k3s-geekzoo/pg-app-user-plane`

```json
{
  "username": "plane",
  "password": "<postgres password>"
}
```

`/k3s-geekzoo/cnpg-aws-credentials`

```json
{
  "ACCESS_KEY_ID": "<aws access key id>",
  "ACCESS_SECRET_KEY": "<aws secret access key>",
  "AWS_REGION": "us-east-2"
}
```

## Redis and RabbitMQ

`/k3s-geekzoo/plane-redis-auth`

```json
{
  "password": "<redis password>"
}
```

`/k3s-geekzoo/plane-rabbitmq-default-user`

```json
{
  "username": "plane",
  "password": "<rabbitmq password>",
  "default_user.conf": "default_user = plane\ndefault_pass = <rabbitmq password>\n"
}
```

## Plane application

`/k3s-geekzoo/plane-app-secrets`

```json
{
  "SECRET_KEY": "<django secret>",
  "AES_SECRET_KEY": "<silo aes key>",
  "LIVE_SERVER_SECRET_KEY": "<live server secret>",
  "PI_INTERNAL_SECRET": "<pi internal secret>",
  "REDIS_URL": "redis://:<redis password>@plane-redis.database.svc.cluster.local:6379/0",
  "DATABASE_URL": "postgresql://plane:<postgres password>@plane-pg-cluster-rw.database.svc.cluster.local:5432/plane",
  "AMQP_URL": "amqp://plane:<rabbitmq password>@plane-rabbitmq.database.svc.cluster.local:5672/plane"
}
```

`/k3s-geekzoo/plane-live-secrets`

```json
{
  "LIVE_SERVER_SECRET_KEY": "<live server secret>",
  "REDIS_URL": "redis://:<redis password>@plane-redis.database.svc.cluster.local:6379/0"
}
```

`/k3s-geekzoo/plane-silo-secrets`

```json
{
  "SILO_HMAC_SECRET_KEY": "<silo hmac key>",
  "AES_SECRET_KEY": "<silo aes key>",
  "DATABASE_URL": "postgresql://plane:<postgres password>@plane-pg-cluster-rw.database.svc.cluster.local:5432/plane",
  "REDIS_URL": "redis://:<redis password>@plane-redis.database.svc.cluster.local:6379/0",
  "AMQP_URL": "amqp://plane:<rabbitmq password>@plane-rabbitmq.database.svc.cluster.local:5672/plane"
}
```

`/k3s-geekzoo/plane-doc-store-secrets`

```json
{
  "FILE_SIZE_LIMIT": "20971520",
  "AWS_S3_BUCKET_NAME": "plane-uploads",
  "USE_MINIO": "0",
  "AWS_ACCESS_KEY_ID": "<plane-uploads ObjectBucketClaim access key>",
  "AWS_SECRET_ACCESS_KEY": "<plane-uploads ObjectBucketClaim secret key>",
  "AWS_REGION": "us-east-1",
  "AWS_S3_ENDPOINT_URL": "https://s3.macbytes.io",
  "AWS_S3_ADDRESSING_STYLE": "path"
}
```

> **Endpoint must be browser-reachable.** With `USE_MINIO=0` Plane hands the
> browser presigned upload URLs built from `AWS_S3_ENDPOINT_URL`. Use the
> external Ceph RGW ingress (`https://s3.macbytes.io`), not the in-cluster
> service (`rook-ceph-rgw-ceph-objectstore.rook-ceph.svc`) — the browser can
> neither resolve the internal name nor make a plaintext request from the HTTPS
> app, so uploads ("failed to upload cover image") fail.

### Bucket CORS

Because the browser uploads cross-origin (`plane.macbytes.io` ->
`s3.macbytes.io`), the `plane-uploads` bucket needs a CORS policy allowing the
Plane origin, otherwise the upload reaches RGW (HTTP 204) but the browser blocks
the response for lack of an `Access-Control-Allow-Origin` header. The
ObjectBucketClaim does NOT manage CORS, so it must be applied to the bucket
directly (re-apply if the bucket is ever recreated). Using the OBC credentials
from the `plane-uploads` secret against the external endpoint:

```sh
aws s3api put-bucket-cors --endpoint-url https://s3.macbytes.io \
  --bucket plane-uploads --cors-configuration '{
    "CORSRules": [{
      "AllowedOrigins": ["https://plane.macbytes.io"],
      "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3600
    }]
  }'
```
