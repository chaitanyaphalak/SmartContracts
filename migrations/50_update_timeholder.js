const TimeHolder = artifacts.require("./TimeHolder.sol");
const Storage = artifacts.require('./Storage.sol');
const StorageManager = artifacts.require('./StorageManager.sol');
const ContractsManager = artifacts.require("./ContractsManager.sol");
const MultiEventsHistory = artifacts.require("./MultiEventsHistory.sol");
const ERC20Manager = artifacts.require("./ERC20Manager.sol");
const ERC20Interface = artifacts.require('ERC20Interface.sol')
const ChronoBankAssetProxy = artifacts.require("./ChronoBankAssetProxy.sol");
const TimeHolderWallet = artifacts.require('./TimeHolderWallet.sol')

module.exports = function(deployer, network) {
      deployer.then(() => TimeHolder.deployed())
      .then(_oldTimeHolder => oldTimeHolder = _oldTimeHolder)

      // 1 - deploy an updated TimeHolder
      .then(() => deployer.deploy(TimeHolder, Storage.address, 'Deposits'))
      .then(() => StorageManager.deployed())
      .then(_storageManager => storageManager = _storageManager)
      .then(() => TimeHolder.deployed())
      .then(_timeHolder => updatedTimeHolder = _timeHolder)
      .then(() => storageManager.giveAccess(updatedTimeHolder.address, 'Deposits'))
      .then(() => {
          if (network == "main") {
             return ERC20Manager.deployed().then(_erc20Manager => _erc20Manager.getTokenAddressBySymbol.call("TIME"))
         } else {
             return ChronoBankAssetProxy.address;
         }
      })
      .then(_timeAddress => updatedTimeHolder.init(ContractsManager.address, _timeAddress, TimeHolderWallet.address))
      .then(() => MultiEventsHistory.deployed())
      .then(_history => _history.authorize(updatedTimeHolder.address))
      .then(() => {
          if (network == "main") {
              return updatedTimeHolder.setLimit(100000000);
          }
      })
      .then(() => console.log("[MIGRATION] [50.1] updated TimeHolder deployed: #done"))

      // 2 - remove old TimeHolder
      .then(() => storageManager.blockAccess(oldTimeHolder.address, 'Deposits'))
      .then(() => MultiEventsHistory.deployed())
      .then(_history => _history.reject(oldTimeHolder.address))
      .then(() => oldTimeHolder.destroy())

      .then(() => console.log("[MIGRATION] [50.2] old TimeHolder destroyed: #done"))
}
