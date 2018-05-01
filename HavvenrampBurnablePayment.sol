// A HavvenrampBurnablePayment is a modification of the BurnablePayment contract.
//
// This version replaces the worker-called "Commit" function with the payer-called "ApproveWorker" function.
// This allows a user without ETH to be registered/approved as the recipient,
// and assumes such a user has a way of contacting the payer to request said registration.
//
// This modification has been sponsored by Havven,
// to be used in the development of a robust, decentralized crypto on-ramp.

pragma solidity ^ 0.4.23;

contract HavvenrampBurnablePaymentFactory {
    event NewHBP(
        address indexed bpAddress,
        address payer,
        uint deposited,
        uint autoreleaseInterval,
        string title,
        string initialStatement
    );

    function newHBP(address payer, uint autoreleaseInterval, string title, string initialStatement)
    external
    payable
    returns (address)
    {
        //pass along any ether to the constructor
        address newHBPAddr = (new HavvenrampBurnablePayment).value(msg.value)(payer, autoreleaseInterval, title, initialStatement);

        emit NewHBP(newHBPAddr, payer, msg.value, autoreleaseInterval, title, initialStatement);

        return newHBPAddr;
    }
}

contract HavvenrampBurnablePayment {
    //title will never change
    string public title;

    //HBP will start with a payer but not a recipient
    address public payer;
    address public recipient;

    address constant BURN_ADDRESS = 0x0;

    //Set to true if fundsRecovered is called (offers another method of detecting recalled HBPs)
    bool recovered = false;

    //Note that these will track, but not influence the HBP logic.
    uint public amountDeposited;
    uint public amountBurned;
    uint public amountReleased;

    //How long should we wait before allowing the default release to be called?
    uint public autoreleaseInterval;

    //Calculated from autoreleaseInterval in commit(),
    //and recaluclated whenever the payer calls delayDefaultRelease()
    //After this time, auto-release can be called by any address.
    uint public autoreleaseTime;

    //Most action happens in the Committed state.
    enum State {
        Open,
        Committed,
        Closed
    }

    //Note that a HBP cannot go from Committed back to either Open state, but it can go from Closed back to Committed
    //Search for Closed and Unclosed events to see how this works.
    State public state;

    modifier inState(State s) {
        require(s == state);
        _;
    }
    modifier onlyPayer() {
        require(msg.sender == payer);
        _;
    }

    event Created(address indexed contractAddress, address payer, uint autoreleaseInterval, string title);
    event FundsAdded(uint amount); //The payer has added funds to the HBP.
    event PayerStatement(string statement);
    event FundsRecovered();
    event RecipientApproved(address recipient);
    event FundsBurned(uint amount);
    event FundsReleased(uint amount);
    event Closed();
    event Unclosed();
    event AutoreleaseDelayed();
    event AutoreleaseTriggered();

    constructor(address _payer, uint _autoreleaseInterval, string _title, string initialStatement)
    public
    payable
    {
        emit Created(this, payer, autoreleaseInterval, title);

        payer = _payer;
        title = _title;
        state = State.Open;
        autoreleaseInterval = _autoreleaseInterval;

        if (msg.value > 0) {
            emit FundsAdded(msg.value);
            amountDeposited += msg.value;
        }

        if (bytes(initialStatement).length > 0) {
            emit PayerStatement(initialStatement);
        }
    }

    function addFunds()
    external
    payable
    onlyPayer()
    {
        require(msg.value > 0);

        emit FundsAdded(msg.value);

        amountDeposited += msg.value;
        if (state == State.Closed) {
            state = State.Committed;
            emit Unclosed();
        }
    }

    function recoverFunds()
    external
    onlyPayer()
    inState(State.Open)
    {
        recovered = true;
        emit FundsRecovered();

        selfdestruct(payer);
    }

    function approveRecipient(address _recipient)
    external
    payable
    onlyPayer()
    inState(State.Open)
    {
        recipient = _recipient;

        state = State.Committed;

        emit RecipientApproved(recipient);

        autoreleaseTime = now + autoreleaseInterval;
    }

    function internalBurn(uint amount)
    internal
    {
        BURN_ADDRESS.transfer(amount);

        amountBurned += amount;
        emit FundsBurned(amount);

        if (address(this).balance == 0) {
            state = State.Closed;
            emit Closed();
        }
    }

    function burn(uint amount)
    external
    inState(State.Committed)
    onlyPayer()
    {
        internalBurn(amount);
    }

    function internalRelease(uint amount)
    internal
    {
        recipient.transfer(amount);

        amountReleased += amount;
        emit FundsReleased(amount);

        if (address(this).balance == 0) {
            state = State.Closed;
            emit Closed();
        }
    }

    function release(uint amount)
    external
    inState(State.Committed)
    onlyPayer()
    {
        internalRelease(amount);
    }

    function logPayerStatement(string statement)
    external
    onlyPayer()
    {
        emit PayerStatement(statement);
    }

    function delayAutorelease()
    external
    onlyPayer()
    inState(State.Committed)
    {
        autoreleaseTime = now + autoreleaseInterval;
        emit AutoreleaseDelayed();
    }

    function triggerAutorelease()
    external
    inState(State.Committed)
    {
        require(now >= autoreleaseTime);

        emit AutoreleaseTriggered();
        internalRelease(address(this).balance);
    }

    function getFullState()
    external
    constant
    returns(State, address, address, string, uint, uint, uint, uint, uint, uint) {
        return (state, payer, recipient, title, address(this).balance, amountDeposited, amountBurned, amountReleased, autoreleaseInterval, autoreleaseTime);
    }
}
