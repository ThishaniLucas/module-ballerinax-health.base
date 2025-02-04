// Copyright (c) 2023, WSO2 LLC. (http://www.wso2.com).

// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at

// http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.


import ballerina/http;
import ballerina/jwt;
import ballerina/mime;
import ballerina/uuid;

# Configs required to generate the client assertion JWT
#
# + clientId - Client ID provided by the token endpoint  
# + tokenEndpoint - Token endpoint  
# + keyFile - Path to private key //todo: add support to accept key store as well  
# + defaultTokenExpTime - Expiration time (in seconds) of the tokens if the token endpoint response does not contain an `expires_in` field  
# + clockSkew - Clock skew (in seconds) that can be used to avoid token validation failures due to clock synchronization problems
public type PkjwtAuthConfig record {|
    string clientId;
    string tokenEndpoint;
    string keyFile;
    int defaultTokenExpTime = 3600;
    decimal clockSkew = 0;
|};

# Class that generates and manages the access tokens.
public isolated class PkjwtAuthProvider {
    private final PkjwtAuthConfig & readonly config;
    private final TokenCache tokenCache;

    public isolated function init(PkjwtAuthConfig config) {
        self.config = config.cloneReadOnly();
        self.tokenCache = new ();
    }

    public isolated function getToken() returns string|HealthcareSecurityError {
        return retrieveToken(self.config, self.tokenCache);
    }
}

isolated function retrieveToken(PkjwtAuthConfig config, TokenCache tokenCache) returns string|HealthcareSecurityError {
    string cachedAccessToken = tokenCache.getAccessToken();
    if cachedAccessToken == "" {
        return retrieveTokenFromEP(config, tokenCache);
    } else {
        if !tokenCache.isAccessTokenExpired() {
            return cachedAccessToken;
        } else {
            lock {
                if !tokenCache.isAccessTokenExpired() {
                    return tokenCache.getAccessToken();
                }
                return retrieveTokenFromEP(config, tokenCache);
            }
        }
    }
}

isolated function retrieveTokenFromEP(PkjwtAuthConfig config, TokenCache tokenCache) returns string|HealthcareSecurityError {
    map<json> sub = {
        "sub": config.clientId
    };

    jwt:IssuerConfig issuerConfig = {
        customClaims: sub,
        issuer: config.clientId,
        audience: config.tokenEndpoint,
        expTime: 300,
        signatureConfig: {
            config: {
                keyFile: config.keyFile
            },
            algorithm: jwt:RS384
        },
        jwtId: uuid:createType4AsString()
    };
    do {
        string jwt = check jwt:issue(issuerConfig);
        final http:Client clientEndpoint = check new (config.tokenEndpoint);
        TokenResponse response = check clientEndpoint->post("/",
            {
            "grant_type": "client_credentials",
            "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": jwt
        },
            mediaType = mime:APPLICATION_FORM_URLENCODED
        );
        string token = response.access_token;
        int exp = response.expires_in ?: config.defaultTokenExpTime;
        tokenCache.update(token, exp, config.clockSkew);
        return token;
    } on fail var e {
        return prepareError(e.message());
    }
}

type TokenResponse record {
    string access_token;
    int? expires_in;
};
