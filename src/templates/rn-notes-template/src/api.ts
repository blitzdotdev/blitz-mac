import AsyncStorage from '@react-native-async-storage/async-storage'

const STORAGE_PREFIX = 'blitz'
const storageKey = (key: string) => `${STORAGE_PREFIX}:${key}`

const AUTH_TOKEN_KEY = storageKey('auth_token')
const REFRESH_TOKEN_KEY = storageKey('refresh_token')
const AUTH_USER_KEY = storageKey('auth_user')
const USERS_KEY = storageKey('users')
const NOTES_KEY = storageKey('notes')

let authToken: string | null = null
let refreshToken: string | null = null

export interface User {
  id: string
  username: string
  email: string
  name: string
  avatar: string | null
  role: string
  created: string
  updated: string
}

export interface Note {
  id: string
  owner_id: string
  title: string
  content: string
  is_public: boolean
  slug: string
  tags: string | null
  cover: string | null
  views: number
  archived: boolean
  deleted_at: string | null
  created: string
  updated: string
}

export interface AuthResponse {
  token: string
  refresh_token: string
  verified?: boolean
  record: User
}

export interface ListResponse<T> {
  items: T[]
  total: number
}

interface StoredUser extends User {
  password: string
}

interface LocalStore {
  users: StoredUser[]
  notes: Note[]
}

const nowISO = () => new Date().toISOString()

const makeId = (prefix: string) =>
  `${prefix}-${Math.random().toString(36).slice(2, 10)}-${Date.now().toString(36)}`

const toPublicUser = (user: StoredUser): User => ({
  id: user.id,
  username: user.username,
  email: user.email,
  name: user.name,
  avatar: user.avatar,
  role: user.role,
  created: user.created,
  updated: user.updated,
})

const createSeedStore = (): LocalStore => {
  const created = nowISO()
  const guestUser: StoredUser = {
    id: 'user-guest',
    username: 'guest',
    email: 'guest@example.com',
    name: 'Guest User',
    avatar: null,
    role: 'guest',
    created,
    updated: created,
    password: '12345678',
  }

  return {
    users: [guestUser],
    notes: [
      {
        id: 'note-welcome',
        owner_id: guestUser.id,
        title: 'Welcome to Notes',
        content: 'This starter app keeps auth and notes locally so you can prototype without backend setup.',
        is_public: true,
        slug: 'welcome-to-notes',
        tags: 'welcome,starter',
        cover: null,
        views: 0,
        archived: false,
        deleted_at: null,
        created,
        updated: created,
      },
      {
        id: 'note-draft',
        owner_id: guestUser.id,
        title: 'Ideas',
        content: 'Use this note to sketch your first feature ideas.',
        is_public: false,
        slug: 'ideas',
        tags: 'draft',
        cover: null,
        views: 0,
        archived: false,
        deleted_at: null,
        created,
        updated: created,
      },
    ],
  }
}

const saveStore = async (store: LocalStore) => {
  await Promise.all([
    AsyncStorage.setItem(USERS_KEY, JSON.stringify(store.users)),
    AsyncStorage.setItem(NOTES_KEY, JSON.stringify(store.notes)),
  ])
}

const loadStore = async (): Promise<LocalStore> => {
  const [usersJSON, notesJSON] = await Promise.all([
    AsyncStorage.getItem(USERS_KEY),
    AsyncStorage.getItem(NOTES_KEY),
  ])

  if (usersJSON && notesJSON) {
    return {
      users: JSON.parse(usersJSON) as StoredUser[],
      notes: JSON.parse(notesJSON) as Note[],
    }
  }

  const seeded = createSeedStore()
  await saveStore(seeded)
  return seeded
}

const getStoredUserRecord = async (): Promise<StoredUser | null> => {
  const storedUser = await getStoredUser()
  if (!storedUser) {
    return null
  }

  const store = await loadStore()
  return store.users.find((candidate) => candidate.id === storedUser.id) ?? null
}

const requireStoredUser = async (): Promise<StoredUser> => {
  const user = await getStoredUserRecord()
  if (!user) {
    throw new Error('Not authenticated')
  }
  return user
}

const sortNotes = (items: Note[], order?: string) => {
  if (!order) {
    return items
  }

  const descending = order.startsWith('-')
  const field = descending ? order.slice(1) : order

  return [...items].sort((lhs, rhs) => {
    const left = lhs[field as keyof Note]
    const right = rhs[field as keyof Note]
    if (left === right) {
      return 0
    }
    if (left == null) {
      return descending ? 1 : -1
    }
    if (right == null) {
      return descending ? -1 : 1
    }
    if (left > right) {
      return descending ? -1 : 1
    }
    return descending ? 1 : -1
  })
}

const generateToken = (userId: string) => `${userId}.${makeId('token')}`

export const setTokens = async (
  token: string | null,
  refresh: string | null = null,
  user: User | null = null
) => {
  authToken = token
  refreshToken = refresh

  if (token) {
    await AsyncStorage.setItem(AUTH_TOKEN_KEY, token)
    if (refresh) {
      await AsyncStorage.setItem(REFRESH_TOKEN_KEY, refresh)
    } else {
      await AsyncStorage.removeItem(REFRESH_TOKEN_KEY)
    }
    if (user) {
      await AsyncStorage.setItem(AUTH_USER_KEY, JSON.stringify(user))
    }
    return
  }

  await Promise.all([
    AsyncStorage.removeItem(AUTH_TOKEN_KEY),
    AsyncStorage.removeItem(REFRESH_TOKEN_KEY),
    AsyncStorage.removeItem(AUTH_USER_KEY),
  ])
}

export const loadTokens = async () => {
  const [storedAuthToken, storedRefreshToken] = await Promise.all([
    AsyncStorage.getItem(AUTH_TOKEN_KEY),
    AsyncStorage.getItem(REFRESH_TOKEN_KEY),
  ])
  authToken = storedAuthToken
  refreshToken = storedRefreshToken
  return { authToken, refreshToken }
}

export const getAuthToken = () => authToken

export const getStoredUser = async (): Promise<User | null> => {
  const stored = await AsyncStorage.getItem(AUTH_USER_KEY)
  if (!stored) {
    return null
  }
  return JSON.parse(stored) as User
}

export const auth = {
  async login(identity: string, password: string): Promise<AuthResponse> {
    const store = await loadStore()
    const normalizedIdentity = identity.trim().toLowerCase()
    const user = store.users.find((candidate) =>
      candidate.email.toLowerCase() === normalizedIdentity ||
      candidate.username.toLowerCase() === normalizedIdentity
    )

    if (!user || user.password !== password) {
      throw new Error('Invalid email, username, or password')
    }

    const record = toPublicUser(user)
    const token = generateToken(user.id)
    const refresh = generateToken(user.id)
    await setTokens(token, refresh, record)

    return {
      token,
      refresh_token: refresh,
      verified: true,
      record,
    }
  },

  async signUp(data: {
    username: string
    email: string
    password: string
    passwordConfirm: string
    name: string
  }): Promise<AuthResponse> {
    if (data.password !== data.passwordConfirm) {
      throw new Error('Passwords do not match')
    }

    const store = await loadStore()
    const normalizedEmail = data.email.trim().toLowerCase()
    const normalizedUsername = data.username.trim().toLowerCase()

    if (store.users.some((user) => user.email.toLowerCase() === normalizedEmail)) {
      throw new Error('That email is already in use')
    }
    if (store.users.some((user) => user.username.toLowerCase() === normalizedUsername)) {
      throw new Error('That username is already in use')
    }

    const timestamp = nowISO()
    const createdUser: StoredUser = {
      id: makeId('user'),
      username: normalizedUsername,
      email: normalizedEmail,
      name: data.name.trim(),
      avatar: null,
      role: 'member',
      created: timestamp,
      updated: timestamp,
      password: data.password,
    }

    store.users.push(createdUser)
    await saveStore(store)

    const record = toPublicUser(createdUser)
    const token = generateToken(createdUser.id)
    const refresh = generateToken(createdUser.id)
    await setTokens(token, refresh, record)

    return {
      token,
      refresh_token: refresh,
      verified: true,
      record,
    }
  },

  async getCurrentUser(): Promise<User> {
    const user = await requireStoredUser()
    return toPublicUser(user)
  },

  async logout(): Promise<void> {
    await setTokens(null)
  },
}

export const notes = {
  async list(params: {
    limit?: number
    offset?: number
    order?: string
    where?: string
  } = {}): Promise<ListResponse<Note>> {
    const store = await loadStore()
    const currentUser = await getStoredUserRecord()

    const visibleNotes = store.notes.filter((note) => {
      if (note.archived || note.deleted_at) {
        return false
      }
      if (currentUser) {
        return note.owner_id === currentUser.id
      }
      return note.is_public
    })

    const sorted = sortNotes(visibleNotes, params.order)
    const offset = params.offset ?? 0
    const limit = params.limit ?? sorted.length

    return {
      items: sorted.slice(offset, offset + limit),
      total: sorted.length,
    }
  },

  async get(id: string): Promise<Note> {
    const store = await loadStore()
    const currentUser = await getStoredUserRecord()
    const note = store.notes.find((candidate) => candidate.id === id && !candidate.archived && !candidate.deleted_at)

    if (!note) {
      throw new Error('Note not found')
    }
    if (currentUser && note.owner_id === currentUser.id) {
      return note
    }
    if (note.is_public) {
      return note
    }

    throw new Error('You do not have access to this note')
  },

  async create(data: {
    title: string
    content: string
    slug: string
    is_public?: boolean
    tags?: string
  }): Promise<Note> {
    const store = await loadStore()
    const currentUser = await requireStoredUser()
    const timestamp = nowISO()

    const note: Note = {
      id: makeId('note'),
      owner_id: currentUser.id,
      title: data.title,
      content: data.content,
      is_public: data.is_public ?? false,
      slug: data.slug,
      tags: data.tags ?? null,
      cover: null,
      views: 0,
      archived: false,
      deleted_at: null,
      created: timestamp,
      updated: timestamp,
    }

    store.notes.unshift(note)
    await saveStore(store)
    return note
  },

  async update(id: string, data: Partial<{
    title: string
    content: string
    is_public: boolean
    tags: string
    archived: boolean
  }>): Promise<Note> {
    const store = await loadStore()
    const currentUser = await requireStoredUser()
    const index = store.notes.findIndex((candidate) => candidate.id === id)

    if (index < 0) {
      throw new Error('Note not found')
    }
    if (store.notes[index].owner_id !== currentUser.id) {
      throw new Error('You can only edit your own notes')
    }

    const updated: Note = {
      ...store.notes[index],
      ...data,
      tags: data.tags ?? store.notes[index].tags,
      updated: nowISO(),
    }

    store.notes[index] = updated
    await saveStore(store)
    return updated
  },

  async delete(id: string): Promise<void> {
    const store = await loadStore()
    const currentUser = await requireStoredUser()
    const note = store.notes.find((candidate) => candidate.id === id)

    if (!note) {
      throw new Error('Note not found')
    }
    if (note.owner_id !== currentUser.id) {
      throw new Error('You can only delete your own notes')
    }

    store.notes = store.notes.filter((candidate) => candidate.id !== id)
    await saveStore(store)
  },
}

export const api = {
  auth,
  notes,
}

export default api
