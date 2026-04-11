import { useCallback, useContext, useEffect, useState } from 'react'
import { Outlet, useNavigate } from 'react-router-dom'
import { AuthContext } from 'react-oauth2-code-pkce'
import { ReadError } from '@iqss/dataverse-client-javascript'
import { User } from '../../users/domain/models/User'
import { SessionContext, SessionError } from './SessionContext'
import { getUser } from '../../users/domain/useCases/getUser'
import { registerUser } from '../../users/domain/useCases/registerUser'
import { UserRepository } from '../../users/domain/repositories/UserRepository'
import { UserDTO } from '../../users/domain/useCases/DTOs/UserDTO'
import { JSDataverseReadErrorHandler } from '@/shared/helpers/JSDataverseReadErrorHandler'
import { ValidTokenNotLinkedAccountFormHelper } from '@/sections/sign-up/valid-token-not-linked-account-form/ValidTokenNotLinkedAccountFormHelper'
import { OIDC_STANDARD_CLAIMS } from '@/sections/sign-up/valid-token-not-linked-account-form/types'
import { ACCOUNT_CREATED_SESSION_STORAGE_KEY } from '@/sections/collection/AccountCreatedAlert'
import { requireAppConfig } from '@/config'
import { QueryParamKey, Route } from '../Route.enum'

export const BEARER_TOKEN_IS_VALID_BUT_NOT_LINKED_MESSAGE =
  'Bearer token is validated, but there is no linked user account.'

interface SessionProviderProps {
  repository: UserRepository
}

export function SessionProvider({ repository }: SessionProviderProps) {
  const navigate = useNavigate()
  const { token, loginInProgress, tokenData } = useContext(AuthContext)
  const [user, setUser] = useState<User | null>(null)
  const [isLoadingUser, setIsLoadingUser] = useState(false)
  const [sessionError, setSessionError] = useState<SessionError | null>(null)

  const handleFetchError = useCallback(
    async (err: unknown) => {
      if (err instanceof ReadError) {
        const readErrorHandler = new JSDataverseReadErrorHandler(err)
        const statusCode = readErrorHandler.getStatusCode()
        const errorMessage =
          readErrorHandler.getReasonWithoutStatusCode() ?? readErrorHandler.getErrorMessage()

        // Handle specific error: Bearer token validated, but no linked user account
        if (readErrorHandler.isBearerTokenValidatedButNoLinkedUserAccountError()) {
          const appConfig = requireAppConfig()

          if (appConfig.oidc.autoRegisterUsers) {
            // Auto-register the user using the OIDC token data instead of showing the sign-up form
            try {
              const formData = {
                username:
                  ValidTokenNotLinkedAccountFormHelper.getTokenDataValue<string>(
                    OIDC_STANDARD_CLAIMS.PREFERRED_USERNAME,
                    'string',
                    tokenData
                  ) ?? '',
                firstName:
                  ValidTokenNotLinkedAccountFormHelper.getTokenDataValue<string>(
                    OIDC_STANDARD_CLAIMS.GIVEN_NAME,
                    'string',
                    tokenData
                  ) ?? '',
                lastName:
                  ValidTokenNotLinkedAccountFormHelper.getTokenDataValue<string>(
                    OIDC_STANDARD_CLAIMS.FAMILY_NAME,
                    'string',
                    tokenData
                  ) ?? '',
                emailAddress:
                  ValidTokenNotLinkedAccountFormHelper.getTokenDataValue<string>(
                    OIDC_STANDARD_CLAIMS.EMAIL,
                    'string',
                    tokenData
                  ) ?? '',
                position: '',
                affiliation: '',
                termsAccepted: true
              }

              const registrationDTO: UserDTO =
                ValidTokenNotLinkedAccountFormHelper.defineRegistrationDTOProperties(
                  formData,
                  tokenData
                )

              await registerUser(repository, registrationDTO)

              sessionStorage.setItem(ACCOUNT_CREATED_SESSION_STORAGE_KEY, 'true')

              const user = await getUser(repository)
              setUser(user)

              navigate(Route.COLLECTIONS_BASE, { replace: true })
            } catch {
              setSessionError({
                statusCode: null,
                message: 'Auto-registration failed. Please try again later.'
              })
            }
          } else {
            // Redirect to the sign-up page with a query param
            setSessionError({ statusCode, message: errorMessage })
            navigate(
              `${Route.SIGN_UP}?${new URLSearchParams({
                [QueryParamKey.VALID_TOKEN_BUT_NOT_LINKED_ACCOUNT]: 'true'
              }).toString()}`
            )
          }
          return
        }

        // Set session error for other ReadError cases
        setSessionError({ statusCode, message: errorMessage })
        return
      }

      // Handle unexpected errors
      setSessionError({
        statusCode: null,
        message: 'An unexpected error occurred while getting the user.'
      })
    },
    [navigate, tokenData, repository]
  )

  const fetchUser = useCallback(async () => {
    setIsLoadingUser(true)

    try {
      const user = await getUser(repository)
      setUser(user)
    } catch (err) {
      await handleFetchError(err)
    } finally {
      setIsLoadingUser(false)
    }
  }, [repository, handleFetchError])

  const refetchUserSession = async () => {
    await fetchUser()
  }

  useEffect(() => {
    if (token && !loginInProgress) {
      void fetchUser()
    }
  }, [token, loginInProgress, fetchUser])

  return (
    <SessionContext.Provider
      value={{
        user,
        isLoadingUser,
        sessionError,
        setUser,
        refetchUserSession
      }}>
      <Outlet />
    </SessionContext.Provider>
  )
}
