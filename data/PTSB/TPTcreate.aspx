
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">
<HTML>
	<HEAD>
		<title>Online Banking Ireland - Ireland's Retail Bank From Permanent TSB</title>
		<meta name="vs_defaultClientScript" content="JavaScript">
		<meta name="vs_targetSchema" content="http://schemas.microsoft.com/intellisense/ie5">
		

<meta http-equiv="refresh" content="300;url=DoLogOff.aspx">

		<script language="JavaScript" src="js/IndexCss.js"></script>
	</HEAD>
	<BODY bottomMargin="0" bgColor="white" leftMargin="0" topMargin="0" rightMargin="0">
		<form name="frmpassword" method="post" action="TPTcreate.aspx" id="frmpassword">
<input type="hidden" name="__EVENTTARGET" id="__EVENTTARGET" value="" />
<input type="hidden" name="__EVENTARGUMENT" id="__EVENTARGUMENT" value="" />
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="" />

<script type="text/javascript">
<!--
var theForm = document.forms['frmpassword'];
if (!theForm) {
    theForm = document.frmpassword;
}
function __doPostBack(eventTarget, eventArgument) {
    if (!theForm.onsubmit || (theForm.onsubmit() != false)) {
        theForm.__EVENTTARGET.value = eventTarget;
        theForm.__EVENTARGUMENT.value = eventArgument;
        theForm.submit();
    }
}
// -->
</script>


<input type="hidden" name="__EVENTVALIDATION" id="__EVENTVALIDATION" value="" />
			<!--MAIN PAGE TABLE - SETS FIXED WIDTH - START-->
			<div id="wrap_all">
	<div id="top">
		<img src="img/ptsb_logot44_wwq.gif" alt="Permanent TSB" class="l">
		<div class="r">
			<p>LoCall
				<span>1890 500 121</span>
				International
				<span>+353 1 212 4101</span></p>
			<p>Mon - Fri 8am - 10pm (Excl. bank hols.), Sat 10am - 2pm, or E-mail <a href="mailto:info@permanenttsb.ie">
					info@permanenttsb.ie</a></p>
			<p><br>
			</p>
			<table border="0">
				<tr>
					<td width="100%" align="center" bgcolor=white><font size="3" face="bold" color=#cc0033><b><span id="lblLstLogin" class="text">Your last successful logon was on 29 December 2010 at 17:00</span></b></font></td>
				</tr>
			</table>
		</div>
	</div> <!-- e top -->
	<div class="clear"></div>
	<div id="mainmenu" align="center">
		<ul>
		</ul>
	</div> <!-- e mainmenu -->
	<div class="clear"></div>

			<div class="inside" id="main">
				<div id="leftmenu">
	<ul>
		<li class="heading">
		Your Account
		<li class="subheading">
		<li class="subheading">
		Account Details
		<li>
			<a href="Account.aspx" onmouseover="self.status='Account Summary'; return true" onmouseout="self.status=''; return true">
				Account Summary</a>
		<li class="subheading">
		Other
		<li class="btm">
			<a href="dologoff.aspx" onmouseover="self.status='Logoff'; return true" onmouseout="self.status=''; return true">
				Logoff</a></li>
	</ul>
	<div class="clear"></div>
</div> <!-- e leftmenu -->

				<div id="rightcol">
					<div id="statement">
						<h4>OPEN24 - CREATE A NEW THIRD PARTY TRANSFER - STEP 1</h4>
							<table width="100%" border="0">
								<tr>
									<td class="contentbold" width="100%">
										<table>
											<tr>
												<td colSpan="2" class='contentboldplus'>
													<span id="lblError" class="ContentBoldPlus" style="color:Red;font-weight:bold;width:100%;"></span>
												</td>
											</tr>
											<tr>
												<td colSpan="2">Please enter the Sort Code and Account Number of the account you wish to set up the payment 
													to:</td>
											</tr>
											<tr>
												<td colSpan="2">
												    <table width=100%>
												        <tr>
												            <td>Sort Code:</td>
												            <td><input name="txtSortCode" type="text" maxlength="6" id="txtSortCode" tabindex="1" style="width:100px;" /></td>
												            <td>Account Number:</td>
												            <td><input name="txtAccountCode" type="text" maxlength="8" id="txtAccountCode" tabindex="1" style="width:164px;" /></td>
												        </tr>
												    </table>
												</td>
										     </tr>
							                <tr><td colspan="2">&nbsp;</td></tr>
											<tr>
												<td colSpan="2">Please enter your own reference 
													for this payment (no more than 18 characters):<br>
													e.g. Your invoice number or account number with the company.
													  In the case of a payment to your credit card company, the reference should be your full card number.
													   The reference will appear to the recipient of the payment.</td>
											</tr>
											<tr>
												<td>Reference:</td>
												<td><input name="txtBillRef" type="text" maxlength="18" id="txtBillRef" tabindex="1" style="width:264px;" /></td>
											</tr>
											<tr>
												<td colSpan="2">&nbsp;</td>
											</tr>
											<tr>
												<td colSpan="2">Please enter a Name for this transfer facility. 
												The name will appear on your own account statement:</td>
											</tr>																						
											<tr>
												<td>Name:</td>
												<td><input name="txtBillName" type="text" maxlength="18" id="txtBillName" tabindex="1" style="width:264px;" /></td>
											</tr>											
											<tr>
												<td colSpan="2">&nbsp;</td>
											</tr>
											<tr>
												<td colSpan="2">Please select the default account you wish to make this payment from:</td>
											</tr>
											<tr>
												<td>From Account:</td>
												<td><select name="ddlAccounts" id="ddlAccounts" tabindex="2" style="width:264px;">
	<option value="99999912345678">Current A/C - 9999</option>

</select></td>
											</tr>
											<tr>
												<td colSpan="2">&nbsp;</td>
											</tr>
											<!--<tr>
												<td colSpan="2">You may enter a description for this utility bill payment (a 
													maximum of 25 characters are allowed):<br>
													e.g. My Home Telephone Bill.</td>
											</tr>
											<tr>
												<td>Bill Description:</td>
												<td><input name="txtBillDesc" type="text" maxlength="25" id="txtBillDesc" tabindex="3" style="width:264px;" /></td>
											</tr>-->
										</table>
										&nbsp;</td>
								</tr>
								<tr>
									<td width="100%">&nbsp;</td>
								</tr>
								<tr>
									<td width="100%">
										<table cellSpacing="0" cellPadding="2" border="0">
											<tr>
												<td class="submitret" onmouseover="self.status='Return'; return true" onmouseout="self.status=''; return true"
													align="center"><a id="lbtnReturn1" tabindex="4" class="subret" href="javascript:__doPostBack('lbtnReturn1','')">RETURN TO ACCOUNT SUMMARY</a></td>
												<td class="submit" onmouseover="self.status='Return'; return true" onmouseout="self.status=''; return true"
													align="center"><a id="lbtnContinue" tabindex="5" class="sub" href="javascript:__doPostBack('lbtnContinue','')">CONTINUE</a></td>
											</tr>
										</table>
										&nbsp;</td>
								<tr><td width="100%">Please Note: permanent tsb cannot take any responsibility for the correct set up
								of this third party transfer and shall not be liable for any delay or error which arises
								 from incomplete, unclear, inconsistent and/or mistaken instructions which the User
								 submits. If you require assistance in setting up this payment please contact 
								 1890 500 121 to speak with one of our Customer Service Advisors.
								</td></tr>										
								</tr>
							</table>
					</div> <!-- e Statement --></div> <!-- e rightcol --></div> <!-- e main -->
			<div class="clear"></div>
<p class="print">To print this page use landscape settings for your printer</p>

<div class="clear"></div>
<div class="clear20"></div>
</form>
	</BODY>
</HTML>
