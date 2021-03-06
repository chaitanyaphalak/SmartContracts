pragma solidity ^0.4.11;

import "./TimeHolderEmitter.sol";
import "../core/common/BaseManager.sol";
import "../core/common/ListenerInterface.sol";
import {ERC20Interface as Asset} from "../core/erc20/ERC20Interface.sol";
import {ERC20Manager as ERC20Service} from "../core/erc20/ERC20Manager.sol";
import "./DepositWalletInterface.sol";
import "./ERC20DepositStorage.sol";
import "../core/lib/SafeMath.sol";


/// @title TimeHolder
/// @notice Contract allows to block some amount of shares" balance to unlock
/// functionality inside a system.
contract TimeHolder is BaseManager, TimeHolderEmitter {

    using SafeMath for uint;

    /** Error codes */

    uint constant ERROR_TIMEHOLDER_ALREADY_ADDED = 12000;
    uint constant ERROR_TIMEHOLDER_TRANSFER_FAILED = 12003;
    uint constant ERROR_TIMEHOLDER_INSUFFICIENT_BALANCE = 12006;
    uint constant ERROR_TIMEHOLDER_LIMIT_EXCEEDED = 12007;

    /** Storage keys */

    StorageInterface.AddressesSet sharesTokenStorage;
    StorageInterface.AddressUIntMapping limitsStorage;

    StorageInterface.AddressOrderedSetMapping listeners;
    StorageInterface.Address walletStorage;
    StorageInterface.Address feeWalletStorage;
    StorageInterface.Address erc20DepositStorage;

    /// @dev Guards invokations only for FeatureManager
    modifier onlyFeatureFeeManager {
        require(msg.sender == lookupManager("FeatureFeeManager"));
        _;
    }

    /// @dev only token registered in whitelist
    modifier onlyAllowedToken(address _token) {
        if (store.includes(sharesTokenStorage, _token)) {
            _;
        }
    }

    /// @notice Constructor
    function TimeHolder(Storage _store, bytes32 _crate) BaseManager(_store, _crate) public {
        sharesTokenStorage.init("sharesContractsStorage_v2");
        limitsStorage.init("limitAmountsStorage_v2");
        listeners.init("listeners_v2");
        walletStorage.init("timeHolderWalletStorage");
        feeWalletStorage.init("timeHolderFeeWalletStorage");
        erc20DepositStorage.init("erc20DepositStorage");
    }

    /// @notice Init TimeHolder contract.
    /// @param _contractsManager address.
    /// @return result code of an operation
    function init(
        address _contractsManager,
        address _defaultToken,
        address _wallet,
        address _feeWallet,
        address _erc20DepositStorage
    )
    public
    onlyContractOwner
    returns (uint)
    {
        require(_defaultToken != 0x0);
        require(_wallet != 0x0);
        require(_feeWallet != 0x0);
        require(_erc20DepositStorage != 0x0);

        BaseManager.init(_contractsManager, "TimeHolder");

        store.set(walletStorage, _wallet);
        store.set(feeWalletStorage, _feeWallet);
        store.set(erc20DepositStorage, _erc20DepositStorage);

        store.add(sharesTokenStorage, _defaultToken);
        store.set(limitsStorage, _defaultToken, 2**255);

        ERC20DepositStorage(_erc20DepositStorage).setSharesContract(_defaultToken);

        return OK;
    }

     /// @notice Gets shares amount deposited by a particular shareholder.
     ///
     /// @param _depositor shareholder address.
     ///
     /// @return shares amount.
    function depositBalance(address _depositor) public view returns (uint) {
        return getDepositBalance(getDefaultShares(), _depositor);
    }

    /// @dev Gets balance of tokens deposited to TimeHolder
    ///
    /// @param _token token to check
    /// @param _depositor shareholder address
    /// @return _balance shares amount.
    function getDepositBalance(
        address _token,
        address _depositor
    )
    public
    view
    returns (uint _balance)
    {
        return getDepositStorage().depositBalance(_token, _depositor);
    }

    /// @dev Gets pair of depositStorage and default token set up for a deposits
    ///
    /// @return {
    ///     "_depositStorage": "deposit storage contract",
    ///     "_token": "default shares contract",
    /// }
    function getDepositStorage() private view returns (ERC20DepositStorage _depositStorage) {
        _depositStorage = ERC20DepositStorage(store.get(erc20DepositStorage));

    }

    /// @notice Adds ERC20-compatible token symbols and put them in the whitelist to be used then as
    /// shares for other contracts and allow users to deposit for this share.
    ///
    /// @dev Allowed only for CBEs
    ///
    /// @param _whitelist list of token addresses that will be allowed to be deposited in TimeHolder
    /// @param _limits list of limits
    function allowShares(address[] _whitelist, uint[] _limits)
    external
    onlyAuthorized
    {
        require(_whitelist.length == _limits.length);

        ERC20Service erc20Service = lookupERC20Service();
        for (uint _idx = 0; _idx < _whitelist.length; ++_idx) {
            require(erc20Service.isTokenExists(_whitelist[_idx]));

            store.add(sharesTokenStorage, _whitelist[_idx]);
            store.set(limitsStorage, _whitelist[_idx], _limits[_idx]);

            _emitSharesWhiteListAdded(_whitelist[_idx], _limits[_idx]);
        }
    }

    /// @notice Removes ERC20-compatible token symbols from TimeHolder so they will be removed
    /// from the whitelist and will not be accessible to be used as shares.
    /// All deposited amounts still will be available to withdraw.
    /// @dev Allowed only for CBEs
    ///
    /// @param _blacklist list of token addresses that will be removed from TimeHolder
    function denyShares(address[] _blacklist)
    external
    onlyAuthorized
    {
        for (uint _idx = 0; _idx < _blacklist.length; ++_idx) {
            store.remove(sharesTokenStorage, _blacklist[_idx]);
            store.set(limitsStorage, _blacklist[_idx], 0);

            _emitSharesWhiteListRemoved(_blacklist[_idx]);
        }
    }

    /// @notice Adds provided listener to observe changes of passed symbol when some amount will be deposited/withdrawn.
    /// Checks passed listener for HolderListenerInterface compatibility.
    /// @dev Allowed only for CBEs
    ///
    /// @param _token token symbol to watch deposits and withdrawals
    /// @param _listener address of a listener to add
    function addListener(address _token, address _listener)
    external
    onlyAuthorized
    {
        require(_token != 0x0);
        require(_listener != 0x0);

        store.add(listeners, bytes32(_token), _listener);

        _emitListenerAdded(_listener, _token);
    }

    /// @notice Removes provided listener from observing changes of passed symbol.
    /// @dev Allowed only for CBEs
    ///
    /// @param _token token symbol to stop watching by a listener
    /// @param _listener address of a listener to remove
    function removeListener(address _token, address _listener)
    external
    onlyAuthorized
    {
        require(store.includes(listeners, bytes32(_token), _listener));

        store.remove(listeners, bytes32(_token), _listener);

        _emitListenerRemoved(_listener, _token);
    }

    /// @notice Sets fee wallet address.
    function setFeeWallet(address _feeWallet)
    public
    onlyAuthorized
    {
        store.set(feeWalletStorage, _feeWallet);
    }

    /// @notice Deposits shares with provided symbol and prove possesion.
    /// Amount should be less than or equal to current allowance value.
    ///
    /// Proof should be repeated for each active period. To prove possesion without
    /// depositing more shares, specify 0 amount.
    ///
    /// @param _token token address for shares
    /// @param _amount amount of shares to deposit, or 0 to just prove.
    ///
    /// @return result code of an operation.
    function deposit(address _token, uint _amount) public returns (uint) {
        return depositFor(_token, msg.sender, _amount);
    }

    /// @notice Deposit own shares and prove possession for arbitrary shareholder.
    /// Amount should be less than or equal to caller current allowance value.
    ///
    /// Proof should be repeated for each active period. To prove possesion without
    /// depositing more shares, specify 0 amount.
    ///
    /// This function meant to be used by some backend application to prove shares possesion
    /// of arbitrary shareholders.
    ///
    /// @param _token token address for shares
    /// @param _target to deposit and prove for.
    /// @param _amount amount of shares to deposit, or 0 to just prove.
    ///
    /// @return result code of an operation.
    function depositFor(address _token, address _target, uint _amount)
    public
    onlyAllowedToken(_token)
    returns (uint)
    {
        require(_token != 0x0);
        require(store.includes(sharesTokenStorage, _token));

        if (_amount > getLimitForToken(_token)) {
            return _emitError(ERROR_TIMEHOLDER_LIMIT_EXCEEDED);
        }

        if (!DepositWalletInterface(wallet()).deposit(_token, msg.sender, _amount)) {
            return _emitError(ERROR_TIMEHOLDER_TRANSFER_FAILED);
        }

        getDepositStorage().depositFor(_token, _target, _amount);

        _goThroughListeners(_token, _target, _amount, _notifyDepositListener);

        _emitDeposit(_token, _target, _amount);

        return OK;
    }

    /// @notice Withdraw shares from the contract, updating the possesion proof in active period.
    /// @param _token token symbol to withdraw from.
    /// @param _amount amount of shares to withdraw.
    /// @return resultCode result code of an operation.
    function withdrawShares(address _token, uint _amount)
    public
    returns (uint resultCode)
    {
        resultCode = _withdrawShares(_token, msg.sender, msg.sender, _amount);
        if (resultCode != OK) {
            return _emitError(resultCode);
        }

        _emitWithdrawShares(_token, msg.sender, _amount, msg.sender);
    }

    /// @notice Force Withdraw Shares
    /// Only CBE members are permited to call this function.
    /// Multisig concensus is required to withdraw shares from shareholder "_from"
    /// and send it to "_to".
    function forceWithdrawShares(address _from, address _token, uint _amount, address _to)
    public
    onlyAuthorized
    returns (uint resultCode) {
        resultCode = multisig();
        if (OK != resultCode) {
            return _emitError(resultCode);
        }

        resultCode = _withdrawShares(_token, _from, _to, _amount);
        if (resultCode != OK) {
            return _emitError(resultCode);
        }

        _emitWithdrawShares(_token, _from, _amount, _to);
    }

    /// @notice Provides a way to support getting additional fee for using features of the system.
    /// @param _account holder of deposits, will pay for using a features
    /// @param _amount size of a fee
    /// @return resultCode result code of the operation
    function takeFeatureFee(address _account, uint _amount)
    public
    onlyFeatureFeeManager
    returns (uint resultCode)
    {
        require(_account != 0x0);
        assert(feeWallet() != 0x0);

        resultCode = _withdrawShares(getDefaultShares(), _account, feeWallet(), _amount);
        if (resultCode != OK) {
            return _emitError(resultCode);
        }

        _emitFeatureFeeTaken(_account, feeWallet(), _amount);
    }

    /// @notice Gets an associated wallet for the time holder
    function wallet() public view returns (address) {
        return store.get(walletStorage);
    }

    /// @notice Gets an associated fee wallet for the time holder
    function feeWallet() public view returns (address) {
        return store.get(feeWalletStorage);
    }

    /// @notice Total amount of shares for provided symbol
    /// @param _token token address to check total shares amout
    /// @return total amount of shares
    function totalShares(address _token) public view returns (uint) {
        return getDepositStorage().totalShares(_token);
    }

    /// @notice Number of shareholders
    /// @return number of shareholders
    function defaultShareholdersCount() public view returns (uint) {
        return getDepositStorage().shareholdersCount(getDefaultShares());
    }

    /// @notice Number of shareholders
    /// @return number of shareholders
    function shareholdersCount(address _token) public view returns (uint) {
        return getDepositStorage().shareholdersCount(_token);
    }

    /// @notice Returns deposit/withdraw limit for shares with provided symbol
    /// @param _token token address to get limit
    /// @return limit number for specified shares
    function getLimitForToken(address _token) public view returns (uint) {
        return store.get(limitsStorage, _token);
    }

    /// @notice Gets shares contract that is set up as default (usually TIMEs)
    function getDefaultShares() public view returns (address) {
        return getDepositStorage().getSharesContract();
    }

    /// @notice Withdraws deposited amount of tokens from account to a receiver address.
    /// Emits its own errorCodes if some will be encountered.
    ///
    /// @param _account an address that have deposited tokens
    /// @param _receiver an address that will receive tokens from _account
    /// @param _amount amount of tokens to withdraw to the _receiver
    ///
    /// @return result code of the operation
    function _withdrawShares(
        address _token,
        address _account,
        address _receiver,
        uint _amount
    )
    internal
    returns (uint)
    {
        uint _depositBalance = getDepositBalance(_token, _account);

        if (_amount > _depositBalance) {
            return _emitError(ERROR_TIMEHOLDER_INSUFFICIENT_BALANCE);
        }

        if (!DepositWalletInterface(wallet()).withdraw(_token, _receiver, _amount)) {
            return _emitError(ERROR_TIMEHOLDER_TRANSFER_FAILED);
        }

        getDepositStorage().withdrawShares(_token, _account, _amount, _depositBalance);

        _goThroughListeners(_token, _account, _amount, _notifyWithdrawListener);

        return OK;
    }

    /// @dev Notifies listener about depositing token with symbol
    function _notifyDepositListener(address _listener, address _token, address _target, uint _amount, uint _balance)
    private
    {
        HolderListenerInterface(_listener).tokenDeposit(_token, _target, _amount, _balance);
    }

    /// @dev Notifies listener about withdrawing token with symbol
    function _notifyWithdrawListener(address _listener, address _token, address _target, uint _amount, uint _balance)
    private
    {
        HolderListenerInterface(_listener).tokenWithdrawn(_token, _target, _amount, _balance);
    }

    /// @dev Iterates through listeners of provided symbol and notifies by calling notification function
    function _goThroughListeners(
        address _token,
        address _target,
        uint _amount,
        function (address, address, address, uint, uint) _notification)
    private
    {
        uint _depositBalance = getDepositBalance(_token, _target);
        StorageInterface.Iterator memory iterator = store.listIterator(listeners, bytes32(_token));
        for (uint i = 0; store.canGetNextWithIterator(listeners, iterator); ++i) {
            address _listener = store.getNextWithIterator(listeners, iterator);
            _notification(_listener, _token, _target, _amount, _depositBalance);
        }
    }

    function lookupERC20Service() internal view returns (ERC20Service) {
        return ERC20Service(lookupManager("ERC20Manager"));
    }

    /** Event emitting */

    function _emitDeposit(address _token, address _who, uint _amount) private {
        TimeHolderEmitter(getEventsHistory()).emitDeposit(_token, _who, _amount);
    }

    function _emitWithdrawShares(address _token, address _who, uint _amount, address _receiver) private {
        TimeHolderEmitter(getEventsHistory()).emitWithdrawShares(_token, _who, _amount, _receiver);
    }

    function _emitListenerAdded(address _listener, address _token) private {
        TimeHolderEmitter(getEventsHistory()).emitListenerAdded(_listener, _token);
    }

    function _emitListenerRemoved(address _listener, address _token) private {
        TimeHolderEmitter(getEventsHistory()).emitListenerRemoved(_listener, _token);
    }

    function _emitFeatureFeeTaken(address _from, address _to, uint _amount) private {
        TimeHolderEmitter(getEventsHistory()).emitFeatureFeeTaken(_from, _to, _amount);
    }

    function _emitSharesWhiteListAdded(address _token, uint _limit) private {
        TimeHolderEmitter(getEventsHistory()).emitSharesWhiteListChanged(_token, _limit, true);
    }

    function _emitSharesWhiteListRemoved(address _token) private {
        TimeHolderEmitter(getEventsHistory()).emitSharesWhiteListChanged(_token, 0, false);
    }

    function _emitError(uint e) private returns (uint) {
        TimeHolderEmitter(getEventsHistory()).emitError(e);
        return e;
    }
}
