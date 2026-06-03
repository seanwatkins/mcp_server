import sys

with open("/opt/mcp_server/mcp-server.lisp", "r") as f:
    content = f.read()

insert_after = '         "token_endpoint_auth_methods_supported" (list "none"))))'

new_handler = """

(hunchentoot:define-easy-handler
    (handle-resource-meta :uri "/.well-known/oauth-protected-resource") ()
  (setf (hunchentoot:content-type*) "application/json")
  (json-encode
   (jobj "resource"                 *server-url*
         "authorization_servers"   (list *server-url*)
         "bearer_methods_supported" (list "header")
         "mcp_endpoint"             (format nil "~A~A" *server-url* *mcp-endpoint*))))
"""

if "oauth-protected-resource" not in content:
    content = content.replace(insert_after, insert_after + new_handler, 1)
    with open("/opt/mcp_server/mcp-server.lisp", "w") as f:
        f.write(content)
    print("patch applied")
else:
    print("already patched")
