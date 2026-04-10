import { useState, useEffect, useCallback } from 'react'
import { auth, loadTokens, setTokens, getAuthToken, User } from '../api'

export interface AuthState {
  user: User | null
  isInitializing: boolean  // Only true during initial auth check
  isActionLoading: boolean // True during login/signup/logout actions
  isAuthenticated: boolean
}

export function useAuth() {
  const [state, setState] = useState<AuthState>({
    user: null,
    isInitializing: true,
    isActionLoading: false,
    isAuthenticated: false,
  })

  // Check auth status on mount
  useEffect(() => {
    const checkAuth = async () => {
      await loadTokens()
      if (getAuthToken()) {
        try {
          const user = await auth.getCurrentUser()
          setState({
            user,
            isInitializing: false,
            isActionLoading: false,
            isAuthenticated: !!user,
          })
        } catch {
          setTokens(null)
          setState({ user: null, isInitializing: false, isActionLoading: false, isAuthenticated: false })
        }
      } else {
        setState({ user: null, isInitializing: false, isActionLoading: false, isAuthenticated: false })
      }
    }
    checkAuth()
  }, [])

  const login = useCallback(async (email: string, password: string) => {
    setState(s => ({ ...s, isActionLoading: true }))
    try {
      const result = await auth.login(email, password)
      setState({
        user: result.record,
        isInitializing: false,
        isActionLoading: false,
        isAuthenticated: true,
      })
      return result
    } catch (error) {
      setState(s => ({ ...s, isActionLoading: false }))
      throw error
    }
  }, [])

  const signUp = useCallback(async (data: {
    username: string
    email: string
    password: string
    passwordConfirm: string
    name: string
  }) => {
    setState(s => ({ ...s, isActionLoading: true }))
    try {
      const result = await auth.signUp(data)
      setState({
        user: result.record,
        isInitializing: false,
        isActionLoading: false,
        isAuthenticated: true,
      })
      return result
    } catch (error) {
      setState(s => ({ ...s, isActionLoading: false }))
      throw error
    }
  }, [])

  const logout = useCallback(async () => {
    setState(s => ({ ...s, isActionLoading: true }))
    try {
      await auth.logout()
    } finally {
      setState({ user: null, isInitializing: false, isActionLoading: false, isAuthenticated: false })
    }
  }, [])

  return {
    ...state,
    // Keep isLoading for backwards compatibility - only true during initial check
    isLoading: state.isInitializing,
    login,
    signUp,
    logout,
  }
}
