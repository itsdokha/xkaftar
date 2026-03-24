class ServiceError(Exception):
    pass


class ConflictError(ServiceError):
    pass


class AuthenticationError(ServiceError):
    pass


class AuthorizationError(ServiceError):
    pass


class NotFoundError(ServiceError):
    pass
