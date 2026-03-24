# OAuth gateway authorization policy.
# user.login  = GitHub username
# user.email  = primary email (may be empty if private)
#
# Add rules here. Examples:
#
#   allow(user: GitHubUser) if user.login = "r33drichards";
#   allow(user: GitHubUser) if user.email.endswith("@yourcompany.com");

allow(user: GitHubUser) if user.login = "r33drichards";
