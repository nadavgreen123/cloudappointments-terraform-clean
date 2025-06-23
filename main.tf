provider "aws" {
  region = "us-east-1"
}

##########################
# S3 Bucket for PDFs     #
##########################
resource "aws_s3_bucket" "pdf_bucket" {
  bucket = "cloudappointments-pdf"
}

##########################
# DynamoDB: Appointments #
##########################
resource "aws_dynamodb_table" "appointments" {
  name         = "Appointments"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "appointmentId"

  attribute {
    name = "appointmentId"
    type = "S"
  }
}

##########################
# DynamoDB: Users Table  #
##########################
resource "aws_dynamodb_table" "users" {
  name         = "Users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"

  attribute {
    name = "userId"
    type = "S"
  }
}

##################################
# IAM Role for Lambda Function   #
##################################
resource "aws_iam_role" "lambda_role" {
  name = "lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy_attachment" "lambda_logs" {
  name       = "attach-lambda-logs"
  roles      = [aws_iam_role.lambda_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

############################
# Lambda Function          #
############################
resource "aws_lambda_function" "api_handler" {
  function_name = "appointmentApiFunction"
  runtime       = "python3.12"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  timeout       = 10

  filename         = "${path.module}/generatePDF_new.zip"
  source_code_hash = filebase64sha256("${path.module}/generatePDF_new.zip")

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.appointments.name
    }
  }
}

########################
# API Gateway          #
########################
resource "aws_apigatewayv2_api" "http_api" {
  name          = "appointments-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api_handler.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "cognito_auth" {
  name                       = "CognitoAuthorizer"
  api_id                     = aws_apigatewayv2_api.http_api.id
  authorizer_type            = "JWT"
  identity_sources           = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.user_pool_client.id]
    issuer   = "https://cognito-idp.us-east-1.amazonaws.com/${aws_cognito_user_pool.user_pool.id}"
  }
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "ANY /{proxy+}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_auth.id
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

################################
# Cognito User Pool & Client   #
################################
resource "aws_cognito_user_pool" "user_pool" {
  name = "cloudappointments-user-pool"
}

resource "aws_cognito_user_pool_client" "user_pool_client" {
  name                             = "cloudappointments-client"
  user_pool_id                     = aws_cognito_user_pool.user_pool.id
  generate_secret                  = false
  allowed_oauth_flows              = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes            = ["email", "openid", "profile"]
  callback_urls                   = ["https://example.com/callback"]
  logout_urls                     = ["https://example.com/logout"]
  supported_identity_providers    = ["COGNITO"]
}
