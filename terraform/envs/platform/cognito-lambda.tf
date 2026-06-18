# Cognito Pre-Token-Generation Lambda — inject custom:tenant_id into the ID token.
#
# Bug (WS3 2026-06-18, BVA-found): the gateway authorizes on the custom:tenant_id
# claim (gateway_go OIDCProvider, TenantIDClaim="custom:tenant_id"), read from the
# Cognito ID token. The SPA uses the OAuth2 authorization-code + PKCE (Hosted UI)
# flow. cognito.tf grants the SPA client READ access to custom:tenant_id, which is
# necessary but NOT sufficient: the Hosted-UI/OAuth2 flow does not surface custom
# attributes in the ID token without a Pre-Token-Generation Lambda. A live PKCE
# login produced an id_token with correct aud/iss/email but NO custom:tenant_id,
# and the gateway rejected it with "Unauthenticated: missing tenant id claim" —
# every real (PKCE) login failed.
#
# Fix: this V1 pre_token_generation Lambda copies the user's custom:tenant_id
# attribute into the ID token's claims via claimsOverrideDetails. V1 supports
# ID-token claim override for the Hosted-Auth/OAuth flow, which is exactly this
# case; V2 (pre_token_generation_config) is unnecessary here.
#
# No dependency cycle: lambda_config (cognito.tf) → function ARN; the function and
# its execution role do not reference the pool; aws_lambda_permission references the
# pool ARN for source_arn. So the edge order is pool → function (via lambda_config)
# and permission → pool (via source_arn) and permission → function — a DAG, no cycle.

data "archive_file" "pretoken" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/pretoken"
  output_path = "${path.module}/lambda/pretoken.zip"
}

resource "aws_iam_role" "pretoken" {
  name = "aegis-cognito-pretoken-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "aegis-cognito-pretoken-${var.environment}"
  }
}

resource "aws_iam_role_policy_attachment" "pretoken_basic" {
  role       = aws_iam_role.pretoken.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "pretoken" {
  function_name = "aegis-cognito-pretoken-${var.environment}"
  role          = aws_iam_role.pretoken.arn

  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.pretoken.output_path
  source_code_hash = data.archive_file.pretoken.output_base64sha256
  timeout          = 5

  tags = {
    Name = "aegis-cognito-pretoken-${var.environment}"
  }
}

# Let the user pool invoke the function. source_arn references the pool ARN; the
# function does not reference the pool, so this closes the wiring without a cycle.
resource "aws_lambda_permission" "cognito_invoke" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pretoken.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}
