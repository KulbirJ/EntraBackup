<#
    Declarative list of everything the backup collects.

    Adding a new backup target should be an edit to this file, never a code change.

    Per-entry keys:
      Name        Directory name under the category, and the key in _meta/run.json.
      Category    Top-level folder under backup/.
      Uri         Graph URI. Single-quoted so $select / $top survive unexpanded.
      Mode        'Collection' pages through @odata.nextLink and writes one file per
                  object; 'Singleton' writes a single settings.json.
      IdField     Property used as the filename. Always an immutable GUID -- naming
                  files after displayName would turn every rename into delete+add.
      NameField   Property surfaced in _index.json so humans can navigate.
      CountUri    Optional $count endpoint, used to size the tenant up front.
      Children    Sub-collections fetched per parent object ({id} is substituted).
      Optional    When true, a 400/403/404 is logged and skipped rather than failing
                  the run. Set on everything that depends on licensing (P1/P2/Intune)
                  or on a feature the tenant may simply not use.
                  400 is in that set because Graph answers deviceManagement endpoints
                  with 400 Bad Request -- not 403 -- on a tenant with no Intune.
      Notes       Shown in docs and in the run log.

    signInActivity is deliberately NOT selected on users: it requires AuditLog.Read.All,
    slows the query considerably, and changes on every sign-in, which would dirty every
    user file on every run and destroy the signal in the diff.
#>
@{
    Endpoints = @(

        # ---------------------------------------------------------------- directory --
        @{
            Name      = 'users'
            Category  = 'directory'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'userPrincipalName'
            CountUri  = '/v1.0/users/$count'
            Uri       = '/v1.0/users?$top=999&$select=id,userPrincipalName,displayName,givenName,surname,mail,mailNickname,otherMails,proxyAddresses,imAddresses,businessPhones,mobilePhone,faxNumber,jobTitle,department,companyName,employeeId,employeeType,employeeHireDate,officeLocation,streetAddress,city,state,postalCode,country,usageLocation,preferredLanguage,userType,accountEnabled,createdDateTime,creationType,externalUserState,identities,onPremisesSyncEnabled,onPremisesImmutableId,onPremisesSamAccountName,onPremisesUserPrincipalName,onPremisesDistinguishedName,onPremisesDomainName,onPremisesSecurityIdentifier,assignedLicenses,assignedPlans,passwordPolicies,lastPasswordChangeDateTime,ageGroup,consentProvidedForMinor,legalAgeGroupClassification,showInAddressList,securityIdentifier'
            Notes     = 'Full user objects. Contains personal data -- keep this repo private.'
        }
        @{
            Name      = 'groups'
            Category  = 'directory'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            CountUri  = '/v1.0/groups/$count'
            Uri       = '/v1.0/groups?$top=999&$select=id,displayName,description,mail,mailEnabled,mailNickname,proxyAddresses,securityEnabled,securityIdentifier,groupTypes,visibility,classification,createdDateTime,expirationDateTime,membershipRule,membershipRuleProcessingState,isAssignableToRole,isManagementRestricted,onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesSecurityIdentifier,preferredDataLocation,preferredLanguage,resourceProvisioningOptions,theme'
            Children  = @(
                @{ Name = 'members'; Uri = '/v1.0/groups/{id}/members?$top=999&$select=id,displayName,userPrincipalName' }
                @{ Name = 'owners';  Uri = '/v1.0/groups/{id}/owners?$top=999&$select=id,displayName,userPrincipalName' }
            )
            Notes     = 'Membership and ownership are fetched per group rather than expanded, because $expand caps at 20 related objects and silently truncates.'
        }
        @{
            Name      = 'directoryRoles'
            Category  = 'directory'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/directoryRoles'
            Children  = @(
                @{ Name = 'members'; Uri = '/v1.0/directoryRoles/{id}/members?$select=id,displayName,userPrincipalName' }
            )
            Notes     = 'Only activated roles are returned by Graph; roleDefinitions below is the complete catalogue.'
        }
        @{
            Name      = 'administrativeUnits'
            Category  = 'directory'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/directory/administrativeUnits?$top=999'
            Children  = @(
                @{ Name = 'members'; Uri = '/v1.0/directory/administrativeUnits/{id}/members?$select=id,displayName' }
            )
            Optional  = $true
        }
        @{
            Name      = 'domains'
            Category  = 'directory'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'id'
            Uri       = '/v1.0/domains'
        }
        @{
            Name      = 'organization'
            Category  = 'directory'
            Mode      = 'Singleton'
            Uri       = '/v1.0/organization'
            Notes     = 'Tenant-level branding, technical contacts, and directory feature settings.'
        }
        @{
            Name      = 'subscribedSkus'
            Category  = 'directory'
            Mode      = 'Collection'
            IdField   = 'skuId'
            NameField = 'skuPartNumber'
            Uri       = '/v1.0/subscribedSkus'
            Notes     = 'Licence inventory. consumedUnits changes as people join and leave, which is meaningful signal rather than noise.'
        }

        # ----------------------------------------------------------------- policies --
        @{
            Name      = 'conditionalAccessPolicies'
            Category  = 'policies'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/identity/conditionalAccess/policies'
            Optional  = $true
            Notes     = 'Requires Entra ID P1 or higher. The single most valuable thing in this backup.'
        }
        @{
            Name      = 'namedLocations'
            Category  = 'policies'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/identity/conditionalAccess/namedLocations'
            Optional  = $true
        }
        @{
            Name     = 'authenticationMethodsPolicy'
            Category = 'policies'
            Mode     = 'Singleton'
            Uri      = '/v1.0/policies/authenticationMethodsPolicy'
            Optional = $true
        }
        @{
            Name     = 'authorizationPolicy'
            Category = 'policies'
            Mode     = 'Singleton'
            Uri      = '/v1.0/policies/authorizationPolicy'
            Notes    = 'Controls default user permissions, guest access level, and self-service app consent.'
        }
        @{
            Name     = 'crossTenantAccessPolicyDefault'
            Category = 'policies'
            Mode     = 'Singleton'
            Uri      = '/v1.0/policies/crossTenantAccessPolicy/default'
            Optional = $true
        }
        @{
            Name      = 'crossTenantAccessPolicyPartners'
            Category  = 'policies'
            Mode      = 'Collection'
            IdField   = 'tenantId'
            NameField = 'tenantId'
            Uri       = '/v1.0/policies/crossTenantAccessPolicy/partners'
            Optional  = $true
        }
        @{
            Name      = 'identitySecurityDefaults'
            Category  = 'policies'
            Mode      = 'Singleton'
            Uri       = '/v1.0/policies/identitySecurityDefaultsEnforcementPolicy'
            Optional  = $true
        }
        @{
            Name      = 'adminConsentRequestPolicy'
            Category  = 'policies'
            Mode      = 'Singleton'
            Uri       = '/v1.0/policies/adminConsentRequestPolicy'
            Optional  = $true
        }
        @{
            Name      = 'permissionGrantPolicies'
            Category  = 'policies'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/policies/permissionGrantPolicies'
            Optional  = $true
        }
        @{
            Name      = 'identityProviders'
            Category  = 'policies'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/identity/identityProviders'
            Optional  = $true
        }

        # ------------------------------------------------------------- applications --
        @{
            Name      = 'applications'
            Category  = 'applications'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/applications?$top=999'
            Notes     = 'App registrations. keyCredentials and passwordCredentials record that a secret exists and when it expires -- Graph never returns the secret material itself.'
        }
        @{
            Name      = 'servicePrincipals'
            Category  = 'applications'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            CountUri  = '/v1.0/servicePrincipals/$count'
            Uri       = '/v1.0/servicePrincipals?$top=999'
            Children  = @(
                @{ Name = 'appRoleAssignedTo'; Uri = '/v1.0/servicePrincipals/{id}/appRoleAssignedTo' }
            )
            Notes     = 'Enterprise applications, including every Microsoft first-party principal.'
        }
        @{
            Name      = 'oauth2PermissionGrants'
            Category  = 'applications'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'clientId'
            Uri       = '/v1.0/oauth2PermissionGrants?$top=999'
            Optional  = $true
            Notes     = 'Delegated consent grants -- new entries here are how most consent-phishing shows up, so this is worth having. Optional only because it needs DelegatedPermissionGrant.Read.All (or Directory.Read.All) on top of Application.Read.All, and returns 403 without it.'
        }

        # -------------------------------------------------------------- governance --
        @{
            Name      = 'roleDefinitions'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/roleManagement/directory/roleDefinitions'
        }
        @{
            Name      = 'roleAssignments'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'roleDefinitionId'
            Uri       = '/v1.0/roleManagement/directory/roleAssignments'
        }
        @{
            Name      = 'roleEligibilitySchedules'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'roleDefinitionId'
            Uri       = '/v1.0/roleManagement/directory/roleEligibilitySchedules'
            Optional  = $true
            Notes     = 'PIM eligible assignments. Requires Entra ID P2.'
        }
        @{
            Name      = 'roleManagementPolicies'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = "/v1.0/policies/roleManagementPolicies?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'"
            Optional  = $true
            Notes     = 'PIM activation rules (approval, MFA, duration). Requires Entra ID P2.'
        }
        @{
            Name      = 'roleManagementPolicyAssignments'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'roleDefinitionId'
            Uri       = "/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'"
            Optional  = $true
        }
        @{
            Name      = 'accessReviewDefinitions'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/identityGovernance/accessReviews/definitions'
            Optional  = $true
            Notes     = 'Requires Entra ID P2.'
        }
        @{
            Name      = 'entitlementAccessPackages'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/identityGovernance/entitlementManagement/accessPackages'
            Optional  = $true
            Notes     = 'Requires Entra ID Governance / P2.'
        }
        @{
            Name      = 'entitlementCatalogs'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/identityGovernance/entitlementManagement/catalogs'
            Optional  = $true
        }
        @{
            Name      = 'entitlementPolicies'
            Category  = 'governance'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/identityGovernance/entitlementManagement/assignmentPolicies'
            Optional  = $true
        }

        # ------------------------------------------------------------------ intune --
        @{
            Name      = 'deviceConfigurations'
            Category  = 'intune'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/deviceManagement/deviceConfigurations'
            Optional  = $true
            Notes     = 'Requires an Intune licence.'
        }
        @{
            Name      = 'deviceCompliancePolicies'
            Category  = 'intune'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/deviceManagement/deviceCompliancePolicies'
            Optional  = $true
        }
        @{
            Name      = 'deviceEnrollmentConfigurations'
            Category  = 'intune'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/deviceManagement/deviceEnrollmentConfigurations'
            Optional  = $true
        }
        @{
            Name      = 'managedAppPolicies'
            Category  = 'intune'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/deviceAppManagement/managedAppPolicies'
            Optional  = $true
            Notes     = 'App protection (MAM) policies.'
        }
        @{
            Name      = 'roleDefinitionsIntune'
            Category  = 'intune'
            Mode      = 'Collection'
            IdField   = 'id'
            NameField = 'displayName'
            Uri       = '/v1.0/deviceManagement/roleDefinitions'
            Optional  = $true
        }
    )
}
