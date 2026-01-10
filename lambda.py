"""
AWS Lambda Function for Serverless User API
============================================
This Lambda function handles HTTP requests (GET and POST) from API Gateway v2.
It performs CRUD operations on a DynamoDB table to manage user data.

Endpoints:
- POST /users: Create/save a new user (requires user_id and name in request body)
- GET /users: Retrieve a user by ID (requires 'id' query parameter)

The function receives events from API Gateway HTTP API (v2) and returns
properly formatted HTTP responses with status codes and JSON bodies.
"""

import json
import boto3
import os

# ============================================================================
# DYNAMODB CONNECTION SETUP
# ============================================================================
# Initialize the DynamoDB resource client (this will use AWS credentials from 
# the Lambda execution role's environment)
dynamodb = boto3.resource('dynamodb')

# Get the table name from environment variable (set by Terraform)
# This allows the same code to work with different table names in different environments
table_name = os.environ['TABLE_NAME']

# Get a reference to the specific DynamoDB table we'll be working with
table = dynamodb.Table(table_name)


def lambda_handler(event, context):
    """
    Main Lambda handler function - entry point for all API Gateway requests.
    
    Parameters:
        event (dict): Contains the HTTP request data from API Gateway v2
                     - requestContext.http.method: HTTP method (GET, POST, etc.)
                     - body: Request body (for POST requests)
                     - queryStringParameters: Query string parameters (for GET requests)
        context: Lambda runtime context (contains execution info, not used here)
    
    Returns:
        dict: API Gateway v2 formatted response
              - statusCode: HTTP status code (200, 404, 500, etc.)
              - body: JSON string with response data or error message
    """
    print("Event Received:", json.dumps(event))
    
    # ========================================================================
    # STEP 1: DETERMINE HTTP METHOD
    # ========================================================================
    # API Gateway HTTP API (v2) stores the HTTP method in the request context
    # Structure: event['requestContext']['http']['method']
    # This tells us what action the client wants to perform
    http_method = event['requestContext']['http']['method']
    print("HTTP Method:", http_method)
    
    # ========================================================================
    # STEP 2: HANDLE POST REQUESTS (CREATE/SAVE USER)
    # ========================================================================
    # POST /users endpoint: Creates a new user in DynamoDB
    # Expected request body JSON: {"user_id": "123", "name": "John Doe"}
    if http_method == 'POST':
        print("Handling POST request")
        try:
            # Parse the JSON request body to extract user data
            body = json.loads(event['body'])
            user_id = body['user_id']  # User ID (primary key in DynamoDB)
            name = body['name']         # User's name
            
            # Save the user to DynamoDB table
            # put_item will create a new item or update if UserID already exists
            table.put_item(Item={'UserID': user_id, 'Name': name})
            
            # Return success response
            return {
                'statusCode': 200,
                'body': json.dumps(f"User {name} saved successfully")
            }
        except Exception as e:
            # Handle any errors (missing fields, invalid JSON, DynamoDB errors, etc.)
            print(f"Error in POST handler: {str(e)}")
            return {'statusCode': 500, 'body': json.dumps(str(e))}
    
    # ========================================================================
    # STEP 3: HANDLE GET REQUESTS (RETRIEVE USER BY ID)
    # ========================================================================
    # GET /users endpoint: Retrieves a user by their ID
    # Expected query parameter: ?id=123
    elif http_method == 'GET':
        try:
            # Extract the user ID from query string parameters
            # Example: GET /users?id=123
            user_id = event['queryStringParameters']['id']
            
            # Query DynamoDB to retrieve the user by their UserID (primary key)
            response = table.get_item(Key={'UserID': user_id})
            
            # Check if the user was found
            if 'Item' in response:
                # User found - return the user data as JSON
                return {'statusCode': 200, 'body': json.dumps(response['Item'])}
            else:
                # User not found - return 404 Not Found
                return {'statusCode': 404, 'body': json.dumps(f"User {user_id} not found")}
        except Exception as e:
            # Handle errors (missing query parameter, invalid ID, DynamoDB errors, etc.)
            print(f"Error in GET handler: {str(e)}")
            return {'statusCode': 500, 'body': json.dumps(str(e))}
    
    # ========================================================================
    # STEP 4: HANDLE UNSUPPORTED HTTP METHODS
    # ========================================================================
    # If the request method is not GET or POST, return 400 Bad Request
    return {'statusCode': 400, 'body': json.dumps('Invalid HTTP method')}

