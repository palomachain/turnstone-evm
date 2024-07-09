#pragma version 0.3.10
#pragma optimize gas
#pragma evm-version shanghai

"""
@title Compass Fee Manager
@license MIT
@author Volume.Finance
@notice v1.0.0
"""

interface ERC20:
    def balanceOf(account: address) -> uint256: view
    def transfer(to: address, amount: uint256): nonpayable

struct FeeArgs:
    community_fee: uint256 # Total amount to alot for community wallet
    security_fee: uint256 # Total amount to alot for security wallet
    fee_payer_paloma_address: bytes32 # Paloma address covering the fees

compass: public(address)
grain: public(address)

# Rewards program
rewards_community_balance: public(uint256) # stores the balance attributed to the community wallet
rewards_security_balance: public(uint256) # stores the balance attributed to the security wallet
funds: public(HashMap[bytes32, uint256]) # stores the spendable balance of paloma addresses
claimable_rewards: public(HashMap[address, uint256]) # stores the claimable balance for eth addresses
total_funds: public(uint256) # stores the balance of total user funds # Steven: Why do we need this?
total_claims: public(uint256) # stores the balance of total claimable rewards # Steven: Why do we need this?

@external
def __init__(_compass: address, grain: address):
    self.compass = _compass
    self.grain = grain

@internal
def compass_check():
    assert msg.sender == self.compass, "Not Compass"

@external
@payable
def deposit(depositor_paloma_address: bytes32):
    # Deposit some balance on the contract to be used when sending messages from Paloma.
    # depositor_paloma_address: paloma address to which to attribute the sent amount
    # amount: amount of COIN to register with compass. Overpaid balance will be sent back.
    self.compass_check()
    self.funds[depositor_paloma_address] = unsafe_add(self.funds[depositor_paloma_address], msg.value)
    self.total_funds = unsafe_add(self.total_funds, msg.value)

@internal
def swap_grain(_grain: address, amount:uint256, dex: address, payload: Bytes[1028], min_grain: uint256) -> uint256:
    assert min_grain > 0, "Min grain must be greater than 0"
    grain_balance: uint256 = ERC20(_grain).balanceOf(self)
    raw_call(dex, payload, value=amount)
    grain_balance = ERC20(_grain).balanceOf(self) - grain_balance
    assert grain_balance >= min_grain, "Insufficient grain received"
    return grain_balance

@external
@nonreentrant('lock')
def withdraw(sender: address, amount:uint256, dex: address, payload: Bytes[1028], min_grain: uint256):
    # Withdraw ramped up claimable rewards from compass. Withdrawals will be swapped and
    # reimbursed in GRAIN.
    # amount: the amount of COIN to withdraw.
    # exchange: address of the DEX to use for exchanging the token
    self.compass_check()
    assert convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), uint256) == min_grain, "SLC is unavailable"
    self.claimable_rewards[sender] = unsafe_sub(self.claimable_rewards[sender], amount)
    self.total_claims = self.total_claims - amount
    assert self.claimable_rewards[sender] >= amount, "Missing claimable rewards"
    _grain: address = self.grain
    grain_balance: uint256 = self.swap_grain(_grain, amount, dex, payload, min_grain)
    ERC20(_grain).transfer(sender, grain_balance)

@external
@payable
def security_fee_topup():
    self.compass_check()
    # Top up the security wallet with the given amount.
    self.rewards_security_balance = unsafe_add(self.rewards_security_balance, msg.value)

@external
def transfer_fees(fee_args: FeeArgs, relayer_fee: uint256, relayer: address):
    # Transfer fees to the community and security wallets.
    # fee_args: the FeeArgs struct containing the fee amounts.
    self.compass_check()
    assert convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), address) == relayer, "SLC is unavailable"
    self.rewards_community_balance = unsafe_add(self.rewards_community_balance, fee_args.community_fee)
    self.rewards_security_balance = unsafe_add(self.rewards_security_balance, fee_args.security_fee)
    self.claimable_rewards[relayer] = unsafe_add(self.claimable_rewards[relayer], relayer_fee)
    total_fee: uint256 = relayer_fee + fee_args.community_fee + fee_args.security_fee
    user_remaining_funds: uint256 = self.funds[fee_args.fee_payer_paloma_address]
    assert user_remaining_funds >= total_fee, "Insufficient funds"
    self.funds[fee_args.fee_payer_paloma_address] = unsafe_sub(user_remaining_funds, total_fee)
    self.total_claims = unsafe_add(self.total_claims, relayer_fee)
    self.total_funds = unsafe_sub(self.total_funds, total_fee)

@external
def reserve_security_fee(sender: address, gas_fee: uint256):
    self.compass_check()
    assert convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), uint256) == gas_fee, "SLC is unavailable"
    _rewards_security_balance: uint256 = self.rewards_security_balance
    if _rewards_security_balance >= gas_fee:
        self.rewards_security_balance = unsafe_sub(_rewards_security_balance, gas_fee)
        self.claimable_rewards[sender] = unsafe_add(self.claimable_rewards[sender], gas_fee)
        self.total_claims = unsafe_add(self.total_claims, gas_fee)

@external
def bridge_community_fee_to_paloma(amount: uint256, dex: address, payload: Bytes[1028], min_grain: uint256) -> uint256:
    _grain: address = self.grain
    _rewards_community_balance: uint256 = self.rewards_community_balance
    assert _rewards_community_balance >= amount, "Insufficient community fee"
    self.rewards_community_balance = unsafe_sub(_rewards_community_balance, amount)
    grain_balance: uint256 = self.swap_grain(_grain, amount, dex, payload, min_grain)
    ERC20(_grain).transfer(self.compass, grain_balance)
    return grain_balance

@external
def update_compass(_new_compass: address):
    self.compass_check()
    assert convert(slice(msg.data, unsafe_sub(len(msg.data), 32), 32), address) == _new_compass, "SLC is unavailable"
    self.compass = _new_compass