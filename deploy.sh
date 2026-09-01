RG=rg-picweb
SWA=swa-picweb-gallery

if ! az account show &> /dev/null; then
    echo "Error: You are not logged into the Azure CLI."
    exit 1
fi

cp staticwebapp.config.json gallery/        # from stage 3 onwards

# Fetch the current deployment token
TOKEN=$(az staticwebapp secrets list -n "$SWA" -g "$RG" \
          --query properties.apiKey -o tsv)

# 3. Deploy.
npx --yes @azure/static-web-apps-cli@latest deploy ./gallery \
  --deployment-token "$TOKEN" \
  --env production
