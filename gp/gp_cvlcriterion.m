function PE2 = gp_cvlcriterion(gp, x, y, varargin)
% GP_CVLCRITERION cvlcriterion which is equal to cross-validation version
%                 of L-criterion
% 
%   Description
%     
%
%   OPTIONS is optional parameter-value pair
%      z      - optional observed quantity in triplet (x_i,y_i,z_i)
%               Some likelihoods may use this. For example, in case of 
%               Poisson likelihood we have z_i=E_i, that is, expected value 
%               for ith case. 
%     
%               
%
%   See also
%     
%
%   References
%     Vehtari & Ojanen(2010). Bayesian preditive methods for model
%     assesment and selection. Statistic Survey Vol 
%     
%     
%

% Copyright (c) 2011 Ville Tolvanen



  ip=inputParser;
  ip.FunctionName = 'GP_CVLCRITERION';
  ip.addRequired('gp',@(x) isstruct(x) || iscell(x));
  ip.addRequired('x', @(x) ~isempty(x) && isreal(x) && all(isfinite(x(:))))
  ip.addRequired('y', @(x) ~isempty(x) && isreal(x) && all(isfinite(x(:))))
  ip.addParamValue('z', [], @(x) isreal(x) && all(isfinite(x(:))))
  ip.parse(gp, x, y, varargin{:});
  % pass these forward
  options=struct();
  z = ip.Results.z;
  if ~isempty(ip.Results.z)
    options.zt=ip.Results.z;
    options.z=ip.Results.z;
  end
  [tn, nin] = size(x);
  if ((isstruct(gp) && isfield(gp.lik.fh, 'trcov')) || (iscell(gp) && isfield(gp{1}.lik.fh,'trcov')))
    % Gaussian likelihood
    [~,~,~,Ey,Vary] = gp_loopred(gp, x, y);
    PE2 = mean((Ey-y).^2 + Vary);

  else
    % Non-Gaussian likelihood
    error('cvlcriterion not sensible for non-gaussian likelihoods');
  end
  
end
