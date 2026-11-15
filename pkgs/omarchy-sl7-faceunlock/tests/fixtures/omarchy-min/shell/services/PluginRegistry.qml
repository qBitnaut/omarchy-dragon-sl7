import QtQuick

QtObject {
  function stampHostCapabilities(firstParty, thirdParty) {
    var source = firstParty[clonedFrom]
    manifest.__hostCapabilities = source && Array.isArray(source.__hostCapabilities)
      ? source.__hostCapabilities.slice() : []
  }

  function addDisabled(config, id) {
    config.disabledPlugins.push(id)
  }

  function enable(config, clonedFrom) {
    addDisabled(config, clonedFrom)
  }
}
