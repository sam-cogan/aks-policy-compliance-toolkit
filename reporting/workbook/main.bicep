// Deploys the "AKS policy non-compliance" Azure Monitor workbook (shared).
// az deployment group create -g <resource-group> -f main.bicep
param location string = resourceGroup().location
param displayName string = 'AKS policy non-compliance'
param workbookId string = guid(resourceGroup().id, displayName)

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookId
  location: location
  kind: 'shared'
  properties: {
    displayName: displayName
    category: 'workbook'
    sourceId: 'azure monitor'
    serializedData: loadTextContent('aks-policy-noncompliance.workbook.json')
  }
}

output workbookResourceId string = workbook.id
