# Reversi Game Engine - Configuration Guide

## Environment Variables

The deployment can be configured using environment variables that are set in the **ECS task definition**. This allows you to change the URL and port without modifying code or configuration files.

### Available Variables

| Variable | Default | Description | Used In |
|----------|---------|-------------|---------|
| `PLAY_HTTP_PORT` | `9000` | Port the application listens on | Docker entrypoint, ECS, application.conf |
| `PLAY_HTTP_ADDRESS` | `0.0.0.0` | IP address to bind to | Docker entrypoint, ECS, application.conf |
| `API_BASE_URL` | `http://localhost:9000` | Base URL for API clients (React frontend) | Docker entrypoint, ECS |
| `CORS_ORIGINS` | Not set | Comma-separated CORS allowed origins | application.conf |
| `API_KEY` | Not set | API key for authentication (injected by GitHub Actions) | application.conf (via GitHub secret) |
| `PLAY_SECRET` | Not set | Play Framework secret key for sessions | application.conf (optional) |

## Configuration Flow

### 1. **Docker Local Development**

```bash
# Default values (localhost:9000)
docker run -p 9000:9000 reversi-game-engine:latest

# Custom URL and port
docker run -p 8080:8080 \
  -e PLAY_HTTP_PORT=8080 \
  -e API_BASE_URL=http://localhost:8080 \
  reversi-game-engine:latest
```

### 2. **ECS Fargate Deployment** (Production)

The `ecs-task-definition.json.template` includes default environment variables:

```json
{
  "environment": [
    {
      "name": "PLAY_HTTP_PORT",
      "value": "9000"
    },
    {
      "name": "PLAY_HTTP_ADDRESS",
      "value": "0.0.0.0"
    },
    {
      "name": "API_BASE_URL",
      "value": "http://localhost:9000"
    }
  ]
}
```

**To change the URL/port for production:**

1. Edit `aws/ecs-task-definition.json.template` and update the environment values:
   ```json
   {
     "name": "API_BASE_URL",
     "value": "https://api.yourdomain.com"
   }
   ```

2. OR modify the values when creating the ECS service:
   ```bash
   aws ecs register-task-definition \
     --cli-input-json file://ecs-task-definition.json \
     --environment name=API_BASE_URL,value=https://api.yourdomain.com
   ```

### 3. **GitHub Actions CI/CD**

The workflow automatically:
- Injects `API_KEY` from the `API_KEY` GitHub secret
- Generates `application.conf` from `application.conf.template`
- Builds the Docker image with all configuration

The `docker-entrypoint.sh` reads all environment variables on startup and logs them:
```
Starting Reversi Game Engine...
Configuration:
  - Address: 0.0.0.0
  - Port: 9000
  - Base URL: http://localhost:9000
  - Config: /app/conf/application.conf
```

## Configuration Priority (Highest to Lowest)

1. **Environment Variables** (set in Docker or ECS)
2. **JAVA_OPTS system properties** (passed to JVM)
3. **application.conf file** (generated from template)
4. **Defaults in application.conf.template**

Example: If you set `PLAY_HTTP_PORT=8080` as an environment variable, the application will use port 8080 even if `application.conf` specifies 9000.

## Common Use Cases

### Change to Custom Domain with HTTPS

```json
{
  "name": "API_BASE_URL",
  "value": "https://api.reversi.yourcompany.com"
},
{
  "name": "PLAY_HTTP_PORT",
  "value": "9000"
}
```

### Run on Different Port

```json
{
  "name": "PLAY_HTTP_PORT",
  "value": "8080"
},
{
  "name": "API_BASE_URL",
  "value": "http://localhost:8080"
}
```

### Enable Additional CORS Origins

```json
{
  "name": "CORS_ORIGINS",
  "value": "http://localhost:3000,https://app.yourcompany.com"
}
```

## Health Check Configuration

The ECS health check uses the `PLAY_HTTP_PORT` environment variable:

```json
"healthCheck": {
  "command": ["CMD-SHELL", "curl -f http://127.0.0.1:$PLAY_HTTP_PORT/health || exit 1"],
  "interval": 30,
  "timeout": 10,
  "retries": 3,
  "startPeriod": 40
}
```

The health check will automatically use the port specified in the environment variable.

## Updating Configuration Without Redeployment

If you're running on ECS and want to change the configuration:

1. **Update the task definition** with new environment variables
2. **Create a new task definition revision**
3. **Update the ECS service** to use the new task definition
4. **Perform a deployment** (forces new tasks to start with new environment)

Example:
```bash
# Update service to use new environment variable
aws ecs update-service \
  --cluster reversi-cluster \
  --service reversi-service \
  --force-new-deployment
```

## Troubleshooting

**The application is not responding on the expected port:**
- Check the Docker logs: `docker logs <container_id>`
- Verify the `PLAY_HTTP_PORT` environment variable is set correctly
- Ensure the port is exposed in Docker and Security Groups

**CORS errors from frontend:**
- Update the `CORS_ORIGINS` environment variable
- Verify the frontend is using the correct `API_BASE_URL`
- Check browser console for specific CORS error details

**Health check failing:**
- Verify the application is running: `curl http://127.0.0.1:9000/health`
- Check CloudWatch logs: `/ecs/reversi-game-engine`
- Ensure `PLAY_HTTP_PORT` matches the container port mapping

