// Cognito Pre-Token-Generation trigger (WS3, 2026-06-18) — inject custom:tenant_id
// into the ID token. The Hosted-UI/OAuth2 (PKCE) flow does NOT surface custom
// attributes in the ID token without this Lambda, and the gateway authorizes on
// the custom:tenant_id claim (gateway_go OIDCProvider). Without it every PKCE
// login fails with "missing tenant id claim".
export const handler = async (event) => {
  const tenantId = event.request?.userAttributes?.["custom:tenant_id"];
  if (tenantId) {
    event.response = {
      claimsOverrideDetails: {
        claimsToAddOrOverride: { "custom:tenant_id": tenantId },
      },
    };
  }
  return event;
};
