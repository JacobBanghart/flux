# flux
# When reinstalling 
flux bootstrap gitlab \
  --deploy-token-auth \
  --owner=jacobmbanghart \
  --repository=flux \
  --branch=main \
  --path=clusters/k3s-cluster \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller
