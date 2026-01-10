# ============================================================================
# TERRAFORM CONFIGURATION FOR SERVERLESS USER API
# ============================================================================
# This Terraform configuration creates a complete serverless API infrastructure on AWS:
# - DynamoDB table for storing user data
# - Lambda function to handle API requests
# - API Gateway HTTP API v2 for REST endpoints
# - IAM roles and policies for secure access
#
# The infrastructure follows best practices:
# - Remote state storage in S3 with state locking via DynamoDB
# - Pay-per-request DynamoDB billing (serverless)
# - Proper IAM permissions following least privilege principle

# ============================================================================
# PROVIDER CONFIGURATION
# ============================================================================
# Configure the AWS provider to specify which AWS region to deploy resources to
provider "aws" {
    region = "ca-central-1"  # Deploy all resources to Canada (Central) region
}

# ============================================================================
# TERRAFORM REMOTE BACKEND CONFIGURATION
# ============================================================================
# Store Terraform state remotely in S3 instead of locally
# Benefits: State is shared, versioned, and backed up
# DynamoDB table provides state locking to prevent concurrent modifications
terraform {
    backend "s3" {
        bucket = "iftekhar-tf-state-2026"                    # S3 bucket to store state file
        key = "projects/04-serverless-api/terraform.tfstate" # Path to state file in bucket
        region = "ca-central-1"                              # Region where S3 bucket exists
        encrypt = true                                        # Encrypt state file at rest
        dynamodb_table = "terraform-lock"                     # DynamoDB table for state locking
    }
}

# ============================================================================
# DYNAMODB TABLE - USER DATA STORAGE
# ============================================================================
# Creates a NoSQL database table to store user information
# Uses PAY_PER_REQUEST billing (serverless) - only pay for what you use
resource "aws_dynamodb_table" "users" {
    name = "serverless-api-users"         # Table name in AWS
    
    # Pay-per-request billing: No need to provision read/write capacity
    # Automatically scales based on traffic - perfect for serverless applications
    billing_mode = "PAY_PER_REQUEST"
    
    # Hash key (primary key) - used to uniquely identify each user
    hash_key = "UserID"

    # Define the attribute that will be used as the primary key
    attribute {
        name = "UserID"
        type = "S"  # "S" = String type in DynamoDB
    }

    # Tags for resource management and cost tracking
    tags = {
        Name = "serverless-api-users"
    }
}
# ============================================================================
# IAM ROLE - LAMBDA EXECUTION PERMISSIONS
# ============================================================================
# IAM role defines what the Lambda function is allowed to do
# The assume_role_policy allows AWS Lambda service to "assume" (use) this role
resource "aws_iam_role" "lambda_role" {
    name = "serverless-api-lambda-role"

    # Trust policy: Allows AWS Lambda service to assume this role
    # This is required for Lambda functions to execute
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action   = "sts:AssumeRole"  # Action that allows role assumption
                Effect   = "Allow"            # Allow this action
                Principal = {                 # Who can assume this role
                    Service = "lambda.amazonaws.com"  # AWS Lambda service
                }
            }
        ]
    })
}
# ============================================================================
# IAM POLICY - GRANT SPECIFIC PERMISSIONS TO LAMBDA
# ============================================================================
# Defines what actions the Lambda function can perform
# Following principle of least privilege - only grant what's needed
resource "aws_iam_policy" "lambda_policy" {
    name = "serverless_lambda_policy"
    
    # Policy document defining permissions
    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                # DynamoDB permissions: Allow Lambda to read and write user data
                Action = [
                    "dynamodb:PutItem",  # Save/create users (POST endpoint)
                    "dynamodb:GetItem",  # Retrieve users by ID (GET endpoint)
                    "dynamodb:Scan",     # Scan table (not currently used, but included for flexibility)
                ]
                Effect = "Allow"
                # Restrict permissions to only this specific DynamoDB table
                Resource = aws_dynamodb_table.users.arn
            },
            {
                # CloudWatch Logs permissions: Allow Lambda to write execution logs
                # Required for debugging and monitoring Lambda function execution
                Action = [
                    "logs:CreateLogGroup",    # Create log group for Lambda
                    "logs:CreateLogStream",   # Create log streams
                    "logs:PutLogEvents"       # Write log entries
                ]
                Effect = "Allow"
                # Allow logging to any log group in any region/account
                Resource = "arn:aws:logs:*:*:*"
            }
        ]
    })
}

# ============================================================================
# ATTACH POLICY TO ROLE
# ============================================================================
# Links the policy (permissions) to the role (Lambda function identity)
resource "aws_iam_role_policy_attachment" "attach" {
    role       = aws_iam_role.lambda_role.name      # The role to attach to
    policy_arn = aws_iam_policy.lambda_policy.arn   # The policy to attach
}

# ============================================================================
# PACKAGE LAMBDA FUNCTION CODE
# ============================================================================
# Creates a ZIP file containing the Lambda function code
# Terraform needs to package the Python code before uploading to AWS
data "archive_file" "lambda_code" {
    type        = "zip"                    # Create a ZIP archive
    source_file = "lambda.py"              # Source Python file to package
    output_path = "lambda_function.zip"    # Output ZIP file name
}
# ============================================================================
# LAMBDA FUNCTION - SERVERLESS API HANDLER
# ============================================================================
# Creates the AWS Lambda function that will process HTTP requests
# This is the serverless compute that runs your Python code
resource "aws_lambda_function" "users_api" {
    filename      = "lambda_function.zip"                    # ZIP file containing function code
    function_name = "my-serverless-api"                      # Name of the Lambda function
    role          = aws_iam_role.lambda_role.arn             # IAM role for permissions
    handler       = "lambda.lambda_handler"                  # Entry point: file.function_name
    runtime       = "python3.11"                             # Python runtime version (assuming Python 3.11)
    
    # Hash of source code - Terraform will update Lambda only when code changes
    source_code_hash = data.archive_file.lambda_code.output_base64sha256

    # Environment variables passed to Lambda function at runtime
    # The Python code reads TABLE_NAME to know which DynamoDB table to use
    environment {
        variables = {
            TABLE_NAME = aws_dynamodb_table.users.name  # DynamoDB table name
        }
    }
    
    # Resource tags for management and cost tracking
    tags = {
        Name = "serverless-api-users"
    }
}

# ============================================================================
# API GATEWAY HTTP API v2 - PUBLIC API ENDPOINT
# ============================================================================
# Creates an HTTP API that receives requests from the internet and forwards them to Lambda
# HTTP API v2 is faster and cheaper than REST API (v1), with simpler configuration

# Create the API Gateway HTTP API
resource "aws_apigatewayv2_api" "http_api" {
    name          = "serverless-http-api"  # API name
    protocol_type = "HTTP"                 # Use HTTP protocol (simpler than REST)
}

# Create a deployment stage (environment)
# The $default stage is automatically used when accessing the API endpoint
resource "aws_apigatewayv2_stage" "default" {
    api_id      = aws_apigatewayv2_api.http_api.id
    name        = "$default"                # Default stage name
    auto_deploy = true                      # Automatically deploy changes (no manual deployment needed)
}

# ============================================================================
# LAMBDA INTEGRATION - CONNECT API GATEWAY TO LAMBDA
# ============================================================================
# Defines how API Gateway forwards requests to the Lambda function
resource "aws_apigatewayv2_integration" "lambda_integration" {
    api_id           = aws_apigatewayv2_api.http_api.id
    integration_type = "AWS_PROXY"                           # Use Lambda proxy integration
    integration_uri  = aws_lambda_function.users_api.invoke_arn  # ARN of Lambda to invoke
    
    payload_format_version = "2.0"
    # AWS_PROXY integration: API Gateway passes entire request to Lambda
    # Lambda receives full event and returns response directly
}

# ============================================================================
# API ROUTES - DEFINE HTTP ENDPOINTS
# ============================================================================
# Each route maps an HTTP method + path to the Lambda integration

# Route 1: POST /users - Create a new user
# Example: POST https://api-id.execute-api.region.amazonaws.com/users
resource "aws_apigatewayv2_route" "post_route" {
    api_id    = aws_apigatewayv2_api.http_api.id
    route_key = "POST /users"  # HTTP method and path pattern
    target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Route 2: GET /users - Get all users (or with query params)
# Example: GET https://api-id.execute-api.region.amazonaws.com/users?id=123
resource "aws_apigatewayv2_route" "get_route" {
    api_id    = aws_apigatewayv2_api.http_api.id
    route_key = "GET /users"   # HTTP method and path pattern
    target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Route 3: GET /users/{id} - Get user by ID (path parameter)
# Example: GET https://api-id.execute-api.region.amazonaws.com/users/123
# Note: Your Lambda code currently uses query params (?id=123), not path params
resource "aws_apigatewayv2_route" "get_user_route" {
    api_id    = aws_apigatewayv2_api.http_api.id
    route_key = "GET /users/{id}"  # Path parameter pattern
    target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# ============================================================================
# LAMBDA PERMISSION - ALLOW API GATEWAY TO INVOKE LAMBDA
# ============================================================================
# This is required security: Lambda functions deny all invocations by default
# This resource grants API Gateway permission to invoke the Lambda function
resource "aws_lambda_permission" "api_gw" {
    statement_id  = "AllowExecutionFromAPIGateway"
    action        = "lambda:InvokeFunction"                           # Permission to invoke
    function_name = aws_lambda_function.users_api.function_name      # Which Lambda function
    principal     = "apigateway.amazonaws.com"                        # Who can invoke (API Gateway)
    source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"  # From which API Gateway
}

# ============================================================================
# OUTPUTS - DISPLAY IMPORTANT INFORMATION AFTER DEPLOYMENT
# ============================================================================
# Outputs are displayed after `terraform apply` completes successfully
# This makes it easy to get the API endpoint URL to use in your applications

output "api_url" {
    description = "The public URL endpoint for your API"
    value       = aws_apigatewayv2_api.http_api.api_endpoint
    # Example output: https://abc123xyz.execute-api.ca-central-1.amazonaws.com
    # You can use this URL to make HTTP requests to your API
}